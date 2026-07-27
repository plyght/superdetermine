const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // Ship a fast binary by default; `zig build -Doptimize=Debug` opts back in.
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    linkLibgit2(b, exe_mod, target, optimize);
    const exe = b.addExecutable(.{ .name = "gr", .root_module = exe_mod });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the gr binary");
    run_step.dependOn(&run_cmd.step);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        // Tests always run in Debug for leak detection and safety checks.
        .optimize = .Debug,
        .link_libc = true,
    });
    linkLibgit2(b, test_mod, target, .Debug);
    const tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    const fmt_paths = &[_][]const u8{ "src", "build.zig" };
    const fmt = b.addFmt(.{ .paths = fmt_paths });
    const fmt_step = b.step("fmt", "Format the source tree");
    fmt_step.dependOn(&fmt.step);

    const fmt_check = b.addFmt(.{ .paths = fmt_paths, .check = true });
    const fmt_check_step = b.step("fmt-check", "Fail if the source tree is unformatted");
    fmt_check_step.dependOn(&fmt_check.step);
}

fn linkLibgit2(
    b: *std.Build,
    m: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    // Build libgit2 (and its bundled deps) from source and statically link it,
    // so the released binary carries no runtime dependency on libgit2.
    const libgit2 = b.dependency("libgit2", .{
        .target = target,
        .optimize = optimize,
    });
    m.linkLibrary(libgit2.artifact("git2"));
}
