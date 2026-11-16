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

    const version = b.option(
        []const u8,
        "version",
        "Version string reported by --version (default: derived from git describe)",
    ) orelse gitVersion(b);
    const build_opts = b.addOptions();
    build_opts.addOption([]const u8, "version", version);
    exe_module.addOptions("build_options", build_opts);
    const exe = b.addExecutable(.{
        .name = "termcolors",
        .root_module = exe_module,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const test_filters = b.option(
        []const []const u8,
        "test-filter",
        "Only run unit tests whose name contains this (repeatable)",
    ) orelse &.{};
    const tests = b.addTest(.{
        .root_module = exe_module,
        .filters = test_filters,
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

    // The tests exec the compiler-emitted binary (same artifact that gets
    // installed to zig-out/bin); install paths aren't known at configure time.
    const integ_opts = b.addOptions();
    integ_opts.addOptionPath("exe_path", exe.getEmittedBin());
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
            // Safe, not fast: the tool parses terminal-supplied bytes and
            // its runtime is I/O-bound, so keep bounds/overflow checks on.
            .optimize = .safe,
            .link_libc = true,
        });
        rel_module.addOptions("build_options", build_opts);
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

/// Version for builds that don't pass `-Dversion`. An exact `vX.Y.Z` tag on a
/// clean tree yields `X.Y.Z`; anything else yields a semver pre-release such
/// as `0.2.0-dev.3+c40c625` (3 commits past v0.2.0), with `.dirty` appended
/// for uncommitted changes. Outside a git checkout: `0.0.0-dev`.
fn gitVersion(b: *std.Build) []const u8 {
    const unknown = "0.0.0-dev";
    // The result depends on HEAD, tags and working-tree dirtiness, none of
    // which the configure cache can track; without this, `zig build` reuses
    // the cached configuration and bakes in a stale version.
    b.graph.poisonCache();

    var code: u8 = undefined;
    const raw = b.runAllowFail(&.{
        "git",      "-C",     b.root.toString(b.allocator) catch @panic("OOM"),
        "describe", "--tags", "--match",
        "v[0-9]*",  "--long", "--dirty",
    }, &code, .ignore) catch return unknown;

    // `v0.2.0-3-gc40c625[-dirty]`
    var desc = std.mem.trim(u8, raw, " \n\r");
    const dirty = std.mem.endsWith(u8, desc, "-dirty");
    if (dirty) desc = desc[0 .. desc.len - "-dirty".len];

    const sha_sep = std.mem.lastIndexOfScalar(u8, desc, '-') orelse return unknown;
    const count_sep = std.mem.lastIndexOfScalar(u8, desc[0..sha_sep], '-') orelse return unknown;
    const tag = desc[1..count_sep];
    const count = desc[count_sep + 1 .. sha_sep];
    const sha = desc[sha_sep + 2 ..]; // skip "-g"

    if (!dirty and std.mem.eql(u8, count, "0")) return tag;
    return b.fmt("{s}-dev.{s}+{s}{s}", .{ tag, count, sha, if (dirty) ".dirty" else "" });
}
