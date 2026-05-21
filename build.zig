const std = @import("std");

const supported_targets = [_]std.Target.Query{
    .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl },
    .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .musl },
    .{ .cpu_arch = .x86_64, .os_tag = .macos },
    .{ .cpu_arch = .aarch64, .os_tag = .macos },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe_module.link_libc = true;
    const exe = b.addExecutable(.{
        .name = "termcolors",
        .root_module = exe_module,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{
        .root_module = exe_module,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // Integration tests: spawn the real binary under a PTY and play "terminal"
    // by responding to OSC queries with a fixture palette. Exercises the full
    // pipeline (raw-mode TTY, batched query write, reply read, parse, output)
    // without needing a real terminal emulator. See tests/integration.zig.
    const integ_module = b.createModule(.{
        .root_source_file = b.path("tests/integration.zig"),
        .target = target,
        .optimize = optimize,
    });
    integ_module.link_libc = true;
    // forkpty lives in libutil on Linux; macOS exposes it in libc.
    if (target.result.os.tag == .linux) integ_module.linkSystemLibrary("util", .{});

    const integ_opts = b.addOptions();
    integ_opts.addOption([]const u8, "exe_path", b.getInstallPath(.bin, "termcolors"));
    integ_module.addOptions("build_options", integ_opts);

    const integ_tests = b.addTest(.{ .root_module = integ_module });
    const run_integ = b.addRunArtifact(integ_tests);
    run_integ.step.dependOn(b.getInstallStep());
    const integ_step = b.step("test-integration", "Run PTY-based integration tests");
    integ_step.dependOn(&run_integ.step);

    const release_step = b.step("release", "Build static binaries for all supported targets");
    for (supported_targets) |query| {
        const resolved = b.resolveTargetQuery(query);
        const rel_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = resolved,
            .optimize = .ReleaseFast,
            .link_libc = true,
        });
        const rel = b.addExecutable(.{
            .name = "termcolors",
            .root_module = rel_module,
        });
        const triple = query.zigTriple(b.allocator) catch @panic("OOM");
        const install = b.addInstallArtifact(rel, .{
            .dest_dir = .{ .override = .{ .custom = b.fmt("dist/{s}", .{triple}) } },
        });
        release_step.dependOn(&install.step);
    }
}
