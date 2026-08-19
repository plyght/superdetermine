const std = @import("std");
const zon = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // Ship a fast binary by default; `zig build -Doptimize=Debug` opts back in.
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });
    const apricot_dep = b.dependency("apricot", .{
        .target = target,
        .optimize = optimize,
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    linkLibgit2(b, exe_mod, target, optimize);
    exe_mod.addImport("apricot", apricot_dep.module("apricot"));

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", zon.version);
    exe_mod.addOptions("build_options", build_options);

    const exe = b.addExecutable(.{ .name = "sdt", .root_module = exe_mod });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the sdt binary");
    run_step.dependOn(&run_cmd.step);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        // Tests always run in Debug for leak detection and safety checks.
        .optimize = .Debug,
        .link_libc = true,
    });
    linkLibgit2(b, test_mod, target, .Debug);
    const apricot_test_dep = b.dependency("apricot", .{
        .target = target,
        .optimize = .Debug,
    });
    test_mod.addImport("apricot", apricot_test_dep.module("apricot"));
    test_mod.addOptions("build_options", build_options);
    const test_filters = b.option(
        []const []const u8,
        "test-filter",
        "Only run tests whose name contains this substring",
    ) orelse &[0][]const u8{};
    const tests = b.addTest(.{ .root_module = test_mod, .filters = test_filters });
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

    const typecheck_step = b.step("typecheck", "Type-check Superdetermine");
    typecheck_step.dependOn(&exe.step);

    const lint_step = b.step("lint", "Run static checks");
    lint_step.dependOn(&fmt_check.step);
    lint_step.dependOn(&exe.step);

    const check_step = b.step("check", "Run all quality gates");
    check_step.dependOn(&fmt_check.step);
    check_step.dependOn(&exe.step);
    check_step.dependOn(&run_tests.step);
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
