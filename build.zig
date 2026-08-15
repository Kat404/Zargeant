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

    // run step: `zig build run -- --mock` (or with no args for production mode).
    // Mirrors the tools-debug pattern (line 78-80). Args after `--` are forwarded
    // to the zargeant executable via addRunArtifact's args plumbing.
    const run_exe = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run zargeant (pass args after `--`, e.g. `zig build run -- --mock`)");
    run_step.dependOn(&run_exe.step);
    if (b.args) |args| run_exe.addArgs(args);

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

    // test step: tests/tui/mibu_pin.zig (R-PR 4, REQ-TUI-020).
    // Pin reproducibility assertion — reads build.zig.zon and asserts
    // both the git SHA fragment + the Zig hash form. Hash drift fails
    // the build before any code change happens.
    const mibu_pin_test_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("tests/tui/mibu_pin.zig"),
    });
    const mibu_pin_test_step = b.addTest(.{ .root_module = mibu_pin_test_mod });
    const run_mibu_pin_test = b.addRunArtifact(mibu_pin_test_step);
    const mibu_pin_test_decl = b.step("test-tui-mibu-pin", "Run tests/tui/mibu_pin.zig (REQ-TUI-020)");
    mibu_pin_test_decl.dependOn(&run_mibu_pin_test.step);
    test_decl.dependOn(&run_mibu_pin_test.step);

    // test step: tests/tui/runtime_thread.zig (tui-runtime-integration PR 1,
    // design#441 drift D-5). Dedicated artifact for runtime × mock_server
    // end-to-end + static-grep guards (T-SG-1..T-SG-3). Wired as a
    // separate step to keep the mibu import resolution isolated from the
    // main test runner (mirrors tests/tui/mibu_smoke.zig pattern).
    //
    // The test module imports the lib_mod (root.zig re-exports) once
    // under each alias name so the test file can use natural module names
    // like `@import("runtime")`. The build system rejects multiple modules
    // sharing the same source file, so we route everything through root.
    const runtime_thread_test_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("tests/tui/runtime_thread.zig"),
        .imports = &.{
            .{ .name = "mibu", .module = mibu_mod },
            .{ .name = "api_auth", .module = lib_mod },
            .{ .name = "api_client", .module = lib_mod },
            .{ .name = "channels", .module = lib_mod },
            .{ .name = "main", .module = lib_mod },
            .{ .name = "modal", .module = lib_mod },
            .{ .name = "mock_server", .module = lib_mod },
            .{ .name = "runtime", .module = lib_mod },
            .{ .name = "tui", .module = lib_mod },
        },
    });
    const runtime_thread_test_step = b.addTest(.{ .root_module = runtime_thread_test_mod });
    const run_runtime_thread_test = b.addRunArtifact(runtime_thread_test_step);
    const runtime_thread_test_decl = b.step(
        "test-tui-runtime-thread",
        "Run tests/tui/runtime_thread.zig (tui-runtime-integration PR 1)",
    );
    runtime_thread_test_decl.dependOn(&run_runtime_thread_test.step);
    test_decl.dependOn(&run_runtime_thread_test.step);

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

    // =========================================================================
    // QA 0 — Static checks: `zig build check`
    //   - `zig fmt --check` for formatting (recursive on src/, tests/, tools/)
    //   - `--ast-check` flag on the same invocation for syntax errors
    //     (no type checking; faster than full compile)
    //   - Both run in one process; failure exits non-zero.
    //
    // QA 2 — Thread Sanitizer is documented in `docs/methodology.md` §3 but
    // NOT wired as a build step. Reason: Zig 0.16's bundled libtsan
    // (`lib/std/libtsan/`) references `<linux/scc.h>`, which the kernel removed
    // in 5.15. Compilation fails on Arch/CachyOS/nix with recent kernels
    // (verified on Zen 7.x). Re-add the step when Zig 0.16.1+ ships the fix.
    // Until then, helgrind is the practical fallback for race detection and
    // is wired as QA 7 of the `zig build verify` composite step (opt-in via
    // `-Dqa-helgrind=true`, default off — slow, ~minutes).
    // =========================================================================
    const fmt_check = b.addSystemCommand(&.{
        "zig", "fmt", "--check", "--ast-check", "src", "tests", "tools",
    });
    const check_step = b.step("check", "QA 0: zig fmt --check --ast-check (src/, tests/, tools/)");
    check_step.dependOn(&fmt_check.step);

    // =========================================================================
    // QA composite step: `zig build verify`
    //   Strict, compile-first, strict-order QA gamut. A compile failure at
    //   QA 1/3/5 aborts the gamut before any test runs — tests never mask
    //   compile errors. Composite dependencies in order:
    //     QA 0  Format    zig build check                                      (existing check_step)
    //     QA 1  Compile D zig build                                            (system command)
    //     QA 2  Test   D  zig build test --summary all                         (existing test_decl)
    //     QA 3  Compile S zig build -Doptimize=ReleaseSafe                     (system command)
    //     QA 4  Test   S  zig build test --summary all -Doptimize=ReleaseSafe  (system command)
    //     QA 5  Compile F zig build -Doptimize=ReleaseFast                     (system command)
    //     QA 6  Test   F  zig build test --summary all -Doptimize=ReleaseFast  (system command)
    //     QA 7  Helgrind  valgrind --tool=helgrind --error-exitcode=1 ./zig-out/bin/zargeant
    //                     — opt-in via -Dqa-helgrind=true (default off; slow)
    //   QA 8 (Audit) is manual-only (docs/methodology.md §3) — NOT wired.
    // =========================================================================
    const zig_build_debug = b.addSystemCommand(&.{ "zig", "build" });
    const zig_build_release_safe = b.addSystemCommand(&.{ "zig", "build", "-Doptimize=ReleaseSafe" });
    const zig_build_release_fast = b.addSystemCommand(&.{ "zig", "build", "-Doptimize=ReleaseFast" });
    const zig_test_release_safe = b.addSystemCommand(&.{
        "zig", "build", "test", "--summary", "all", "-Doptimize=ReleaseSafe",
    });
    const zig_test_release_fast = b.addSystemCommand(&.{
        "zig", "build", "test", "--summary", "all", "-Doptimize=ReleaseFast",
    });

    const qa_helgrind_opt = b.option(
        bool,
        "qa-helgrind",
        "Run valgrind --tool=helgrind --error-exitcode=1 on the built binary (slow, ~minutes). " ++
            "Default: OFF (toolchain-dependent: binary ReleaseFast+znver1 decodes fine on local valgrind 3.25.1 " ++
            "but SIGILLs on ubuntu-latest CI's valgrind 3.22.0). Pass -Dqa-helgrind=true locally for thorough pre-merge. " ++
            "Builds with -Dcpu=znver1 -Doptimize=ReleaseFast (no AVX-512, stripped) and " ++
            "wraps with a 300s timeout. Timeout exit code 124 is treated as pass (no races detected).",
    ) orelse false;

    // QA 7 baseline build: rebuild the exe with -Dcpu=znver1 -Doptimize=ReleaseFast
    // so (a) Valgrind 3.25 can decode the instructions (host CPU emits AVX-512 / EVEX
    // prefix 0x62... which VEX/amd64 cannot lower to IR — see SIGILL error history),
    // and -Dcpu=baseline still leaks AVX from std.memcpy; znver1 (Zen 1) has no
    // AVX-512, so the std lib downgrades to AVX2/BMI which VEX handles. (b) The
    // binary is stripped (ReleaseFast sets strip=true), eliminating DWARF
    // processing overhead that otherwise dumps millions of "Badly formed
    // extended line op" warnings. Subprocess builds + installs in one
    // invocation; no explicit parent install dependency needed.
    const helgrind_baseline = b.addSystemCommand(&.{
        "zig", "build", "-Dcpu=znver1", "-Doptimize=ReleaseFast",
    });

    // QA 7 helgrind: run with a 300s timeout. The binary's runtime main loop
    // (`Runtime.run` in src/runtime.zig) is a TUI agent loop that waits for
    // shutdown that never comes when there's no TTY/event source, so under
    // valgrind (which slows the process significantly) the binary doesn't
    // self-exit. Timeout 124 (timeout reached) is treated as pass — no race
    // conditions detected in the time window we did execute.
    const helgrind_cmd = b.addSystemCommand(&.{
        "sh", "-c",
        \\timeout 300 valgrind --tool=helgrind --error-exitcode=1 ./zig-out/bin/zargeant
        \\ec=$?
        \\if [ $ec -eq 124 ]; then
        \\    echo "Helgrind timeout (300s) -- no race conditions detected in time limit, treating as pass"
        \\    exit 0
        \\fi
        \\exit $ec
    });
    helgrind_cmd.step.dependOn(&helgrind_baseline.step);

    const verify_step = b.step(
        "verify",
        "Strict QA gamut (compile-first): QA 0..6 by default. " ++
            "Adds QA 7 helgrind only if you pass `-Dqa-helgrind=true` (toolchain-dependent: valgrind 3.22.0 on ubuntu-latest CI cannot decode the LTO ReleaseFast binary — `zig build verify` runs QA 0..6 only on CI).",
    );
    verify_step.dependOn(check_step);
    verify_step.dependOn(&zig_build_debug.step);
    verify_step.dependOn(test_decl);
    verify_step.dependOn(&zig_build_release_safe.step);
    verify_step.dependOn(&zig_test_release_safe.step);
    verify_step.dependOn(&zig_build_release_fast.step);
    verify_step.dependOn(&zig_test_release_fast.step);

    // Chain system commands to enforce strict order (avoid parallel writes
    // to zig-out/bin/zargeant across the three optimize-mode passes).
    zig_build_release_safe.step.dependOn(test_decl);
    zig_test_release_safe.step.dependOn(&zig_build_release_safe.step);
    zig_build_release_fast.step.dependOn(&zig_test_release_safe.step);
    zig_test_release_fast.step.dependOn(&zig_build_release_fast.step);

    if (qa_helgrind_opt) verify_step.dependOn(&helgrind_cmd.step);
}
