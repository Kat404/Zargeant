const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{ .default_target = .{} });
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Prioritize performance, safety, or fast compilation (Debug, ReleaseSafe, ReleaseFast)",
    ) orelse .Debug;

    // lib: harness (static library)
    const lib_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/root.zig"),
    });
    const lib = b.addLibrary(.{
        .name = "harness",
        .linkage = .static,
        .root_module = lib_mod,
    });
    b.installArtifact(lib);

    // exe: zargeant
    const exe_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/root.zig"),
    });
    exe_mod.single_threaded = false;
    const exe = b.addExecutable(.{
        .name = "zargeant",
        .root_module = exe_mod,
    });
    exe.lto = if (optimize == .ReleaseFast) .full else null;
    exe.root_module.strip = optimize == .ReleaseFast;
    b.installArtifact(exe);

    // exe: tools/debug_call.zig (manual-only API key probe).
    // tls-handrolled (sdd id=323, T3.5): wires the micro-CLI as a
    // runnable step. Imports the same api_auth/api_client/logger
    // modules the main zargeant exe uses (no code duplication).
    const debug_call_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("tools/debug_call.zig"),
        .imports = &.{
            .{ .name = "api_auth", .module = lib_mod },
            .{ .name = "api_client", .module = lib_mod },
            .{ .name = "logger", .module = lib_mod },
        },
    });
    const debug_call_exe = b.addExecutable(.{
        .name = "debug-call",
        .root_module = debug_call_mod,
    });
    b.installArtifact(debug_call_exe);
    const debug_call_run = b.addRunArtifact(debug_call_exe);
    const debug_call_step = b.step("tools-debug", "Run tools/debug_call.zig with stdin key");
    debug_call_step.dependOn(&debug_call_run.step);

    // test step
    const test_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/root.zig"),
    });
    test_mod.addIncludePath(b.path("test"));
    const test_step = b.addTest(.{ .root_module = test_mod });
    const run_test = b.addRunArtifact(test_step);
    const test_decl = b.step("test", "Run unit tests");
    test_decl.dependOn(&run_test.step);

    // test step: tools/debug_call.zig in-file grep-fail tests.
    // tls-handrolled (sdd id=323, T3.5): the in-file tests in
    // tools/debug_call.zig MUST be wired into a separate test step so
    // they actually run under `zig build test`. Without this wiring
    // (which is the bug discovered at C6), the grep-fail invariants
    // are silently never enforced.
    const tools_test_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("tools/debug_call.zig"),
        .imports = &.{
            .{ .name = "api_auth", .module = lib_mod },
            .{ .name = "api_client", .module = lib_mod },
            .{ .name = "logger", .module = lib_mod },
        },
    });
    const tools_test_step = b.addTest(.{ .root_module = tools_test_mod });
    const run_tools_test = b.addRunArtifact(tools_test_step);
    const tools_test_decl = b.step("test-tools", "Run tools/ in-file tests");
    tools_test_decl.dependOn(&run_tools_test.step);
    test_decl.dependOn(&run_tools_test.step);
}
