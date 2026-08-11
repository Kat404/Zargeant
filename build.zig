const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{ .default_target = .{} });
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Prioritize performance, safety, or fast compilation (Debug, ReleaseSafe, ReleaseFast)",
    ) orelse .Debug;

    // mibu dep (github.com/xyaman/mibu, MIT, Zig 0.16 tested). Pinned at
    // 636a36a353614da2a537b060c33f17d608915eab per build.zig.zon. The
    // module is wired into tui_mod (always), test_mod (always), and
    // tui-recovery R-PR 2 added lib_mod + exe_mod so main.zig can
    // transitively pull in src/tui.zig → @import("mibu"). R-PR 4
    // formalizes this addition per design#408 §2.3.
    const mibu_dep = b.dependency("mibu", .{
        .target = target,
        .optimize = optimize,
    });
    const mibu_mod = mibu_dep.module("mibu");

    // lib: harness (static library)
    const lib_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/root.zig"),
        .imports = &.{
            .{ .name = "mibu", .module = mibu_mod },
        },
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
        .imports = &.{
            .{ .name = "mibu", .module = mibu_mod },
        },
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
    // tls-handrolled (sdd id=323, T3.5): wires the micro-CLI as a runnable step.
    // Imports point to lib_mod (src/root.zig); src/root.zig re-exports the
    // necessary symbols (initGlobal, deinitGlobal, validateFormat, validateViaApi,
    // etc.) so the imports resolve through the lib_mod namespace without forcing
    // the source files to become independent module roots.
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

    // tui_mod: exposes mibu (github.com/xyaman/mibu, MIT, Zig 0.16 tested)
    // under `@import("mibu")` so that src/tui.zig and tests/tui/* can
    // consume mibu symbols via the build system's `addImport` indirection.
    // tui (PR 1, sdd id=381 task 1.1) is the first slice to add a dep since
    // the project bootstrap. mibu replaced libvaxis (was vendored at
    // vendor/libvaxis/ in the squashed-away 5 libvaxis commits, now wiped
    // from this branch) because libvaxis v0.5.1 transitive deps don't
    // compile on Zig 0.16 -- see obs#399 for the full replacement research.
    const tui_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/tui.zig"),
    });
    tui_mod.addImport("mibu", mibu_mod);

    // test step
    const test_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/root.zig"),
        .imports = &.{
            .{ .name = "mibu", .module = mibu_mod },
        },
    });
    test_mod.addIncludePath(b.path("test"));
    const test_step = b.addTest(.{ .root_module = test_mod });
    const run_test = b.addRunArtifact(test_step);
    const test_decl = b.step("test", "Run unit tests");
    test_decl.dependOn(&run_test.step);

    // test step: tests/tui/mibu_smoke.zig (PR 1, task 1.1 RED guard).
    // Wired as a separate test artifact so its import of `@import("mibu")`
    // resolves against the zig-fetched mibu source. Mirrors the
    // tools/debug_call test-step pattern (C6 from tls-handrolled
    // remediation, engram id=331).
    const tui_test_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("tests/tui/mibu_smoke.zig"),
        .imports = &.{
            .{ .name = "mibu", .module = mibu_mod },
        },
    });
    const tui_test_step = b.addTest(.{ .root_module = tui_test_mod });
    const run_tui_test = b.addRunArtifact(tui_test_step);
    const tui_test_decl = b.step("test-tui", "Run tests/tui/ in-file tests");
    tui_test_decl.dependOn(&run_tui_test.step);
    test_decl.dependOn(&run_tui_test.step);

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
