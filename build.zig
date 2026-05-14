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

    const exe = b.addExecutable(.{
        .name = "termcolors",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    const release_step = b.step("release", "Build static binaries for all supported targets");
    for (supported_targets) |query| {
        const resolved = b.resolveTargetQuery(query);
        const rel = b.addExecutable(.{
            .name = "termcolors",
            .root_source_file = b.path("src/main.zig"),
            .target = resolved,
            .optimize = .ReleaseFast,
        });
        const triple = query.zigTriple(b.allocator) catch @panic("OOM");
        const install = b.addInstallArtifact(rel, .{
            .dest_dir = .{ .override = .{ .custom = b.fmt("dist/{s}", .{triple}) } },
        });
        release_step.dependOn(&install.step);
    }
}
