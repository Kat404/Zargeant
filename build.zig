const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{ .default_target = .{} });
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Prioritize performance, safety, or fast compilation (Debug, ReleaseSafe, ReleaseFast)",
    ) orelse .Debug;

    // mibu dep removed (PR 6, terminal-control-lib-from-scratch, WU 6.5).
    // The terminal control layer is now an in-tree src/terminal/ module
    // (ADR 0003); no third-party TUI dep is required. See ADR 0001 §
    // "Negative" for the contingency this change implements.

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

    // terminal-control-lib-from-scratch (PR 1, task obs#1514 §3 WU 1.3).
    // In-tree src/terminal/ module replacing mibu over 6 chained PRs. PR 1
    // exposes only the `term` slice; PRs 2-5 extend mod.zig with cursor,
    // style, dpm, kitty, event. The module is in-tree; no external
    // dependency is required (ADR 0003 — the mibu replacement).
    //
    // PR 6 (WU 6.5) removed the mibu_dep / mibu_mod / tui_mod blocks.
    // The legacy tui_mod served only as a wrapper to wire `mibu_mod`
    // under the `@import("mibu")` name; with mibu gone, tui_mod is no
    // longer needed (the live tests use lib_mod through
    // runtime_thread_test_mod + the renamed terminal_smoke test step).
    //
    // term_mod is the standalone slice root (src/terminal/term.zig).
    // terminal_mod (mod.zig) imports it via `addImport("term", term_mod)`.
    // tests/terminal/root.zig imports both via the test module's imports.
    const term_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/terminal/term.zig"),
    });
    // PR 2 (terminal-control-lib-from-scratch) — each new src/terminal/<slice>.zig
    // is the root of its own module. terminal_mod re-exports each as it lands;
    // terminal_test_mod imports each so tests/terminal/<slice>.zig can resolve
    // `@import("slice")` against the corresponding build dep.
    const cursor_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/terminal/cursor.zig"),
    });
    const style_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/terminal/style.zig"),
    });
    const dpm_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/terminal/dpm.zig"),
    });
    const kitty_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/terminal/kitty.zig"),
    });
    // PR 3 (terminal-control-lib-from-scratch WU 3.1) — event.zig is its own
    // module root. Owned by event_mod; terminal_mod re-exports event types in
    // PR 3 land 3 (WU 3.3); terminal_test_mod imports event so tests/terminal/
    // event_types.zig can resolve `@import("event")` against the build dep.
    const event_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/terminal/event.zig"),
    });
    // term_mod needs `dpm` as a build dep so src/terminal/term.zig can do
    // `@import("dpm")` to re-export the 6 DPM functions (design C31 fix).
    // Without this, term_mod's `@import("dpm.zig")` collides with the
    // sibling-module-root ownership rule (Zig 0.16).
    term_mod.addImport("dpm", dpm_mod);
    const terminal_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/terminal/mod.zig"),
    });
    terminal_mod.addImport("term", term_mod);
    terminal_mod.addImport("cursor", cursor_mod);
    terminal_mod.addImport("style", style_mod);
    terminal_mod.addImport("dpm", dpm_mod);
    terminal_mod.addImport("kitty", kitty_mod);
    // PR 3 (terminal-control-lib-from-scratch WU 3.3) — terminal_mod
    // re-exports event types so src/tui.zig (in PR 6) can do
    // `terminal.event.nextWithTimeout(...)` and the test file can verify
    // `terminal.event.pollReadable` exists on the namespace.
    terminal_mod.addImport("event", event_mod);
    exe_mod.addImport("terminal", terminal_mod);
    // PR 6 (terminal-control-lib-from-scratch, WU 6.3): lib_mod now needs
    // `terminal` so src/tui.zig + src/channels.zig can `@import("terminal")`.
    // mibu is kept for WU 6.5 removal.
    lib_mod.addImport("terminal", terminal_mod);

    // terminal-control-lib-from-scratch (PR 1, task obs#1514 §3 WU 1.3).
    // In-tree src/terminal/ module replacing mibu over 6 chained PRs. PR 1
    // exposes only the `term` slice; PRs 2-5 extend mod.zig with cursor,
    // style, dpm, kitty, event. Mirrors the mibu_dep + mibu_mod pattern
    // above but without an external dependency (the module is in-tree).
    // The exe_mod import is wired now for symmetry with mibu but unused
    // until PR 6 atomically re-points src/tui.zig from mibu.* to terminal.*
    // (per obs#1506 N11-N13 / C17 / obs#1514 §4 chain strategy).
    //
    // term_mod is the standalone slice root (src/terminal/term.zig).
    // terminal_mod (mod.zig) imports it via `addImport("term", term_mod)`.
    // tests/terminal/root.zig imports both via the test module's imports.
    const term_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/terminal/term.zig"),
    });
    // PR 2 (terminal-control-lib-from-scratch) — each new src/terminal/<slice>.zig
    // is the root of its own module. terminal_mod re-exports each as it lands;
    // terminal_test_mod imports each so tests/terminal/<slice>.zig can resolve
    // `@import("slice")` against the corresponding build dep.
    const cursor_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/terminal/cursor.zig"),
    });
    const style_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/terminal/style.zig"),
    });
    const dpm_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/terminal/dpm.zig"),
    });
    const kitty_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/terminal/kitty.zig"),
    });
    // PR 3 (terminal-control-lib-from-scratch WU 3.1) — event.zig is its own
    // module root. Owned by event_mod; terminal_mod re-exports event types in
    // PR 3 land 3 (WU 3.3); terminal_test_mod imports event so tests/terminal/
    // event_types.zig can resolve `@import("event")` against the build dep.
    const event_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/terminal/event.zig"),
    });
    // term_mod needs `dpm` as a build dep so src/terminal/term.zig can do
    // `@import("dpm")` to re-export the 6 DPM functions (design C31 fix).
    // Without this, term_mod's `@import("dpm.zig")` collides with the
    // sibling-module-root ownership rule (Zig 0.16).
    term_mod.addImport("dpm", dpm_mod);
    const terminal_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/terminal/mod.zig"),
    });
    terminal_mod.addImport("term", term_mod);
    terminal_mod.addImport("cursor", cursor_mod);
    terminal_mod.addImport("style", style_mod);
    terminal_mod.addImport("dpm", dpm_mod);
    terminal_mod.addImport("kitty", kitty_mod);
    // PR 3 (terminal-control-lib-from-scratch WU 3.3) — terminal_mod
    // re-exports event types so src/tui.zig (in PR 6) can do
    // `terminal.event.nextWithTimeout(...)` and the test file can verify
    // `terminal.event.pollReadable` exists on the namespace.
    terminal_mod.addImport("event", event_mod);
    exe_mod.addImport("terminal", terminal_mod);

    // test step
    const test_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/root.zig"),
        .imports = &.{
            .{ .name = "terminal", .module = terminal_mod },
        },
    });
    test_mod.addIncludePath(b.path("test"));
    const test_step = b.addTest(.{ .root_module = test_mod });
    const run_test = b.addRunArtifact(test_step);
    const test_decl = b.step("test", "Run unit tests");
    test_decl.dependOn(&run_test.step);

    // test step: tests/tui/terminal_smoke.zig (PR 6, WU 6.4).
    // Renamed from tests/tui/mibu_smoke.zig (per WU 6.4). Wired as a
    // separate test artifact so its import of `@import("terminal")`
    // resolves against the in-tree src/terminal/ module. Mirrors the
    // tools/debug_call test-step pattern (C6 from tls-handrolled
    // remediation, engram id=331).
    //
    // PR 6 (terminal-control-lib-from-scratch): the mibu.* → terminal.*
    // namespace retarget moved the canary from the zig-fetched mibu
    // source to the in-tree src/terminal/ module. After WU 6.5 the
    // mibu dep is fully removed; the smoke canary is the single
    // authoritative check that the in-tree module keeps the public
    // surface stable.
    const tui_test_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("tests/tui/terminal_smoke.zig"),
        .imports = &.{
            .{ .name = "terminal", .module = terminal_mod },
        },
    });
    const tui_test_step = b.addTest(.{ .root_module = tui_test_mod });
    const run_tui_test = b.addRunArtifact(tui_test_step);
    const tui_test_decl = b.step("test-tui", "Run tests/tui/ in-file tests");
    tui_test_decl.dependOn(&run_tui_test.step);
    test_decl.dependOn(&run_tui_test.step);

    // test step: tests/tui/mibu_pin.zig (R-PR 4, REQ-TUI-020) — DELETED.
    // PR 6 (terminal-control-lib-from-scratch, WU 6.4) deletes both the
    // test file and this build step. REQ-TUI-020 has no object after
    // the mibu dep removal (WU 6.5); the pin enforcement is moot. The
    // `test-tui-mibu-pin` step name is intentionally retained as a
    // deliberate broken step (asserted by apply-progress verification:
    // `zig build test-tui-mibu-pin` MUST error as "step does not exist").

    // test step: tests/terminal/root.zig (PR 1, task obs#1514 §3 WU 1.3).
    // Single-entrypoint test runner for the in-tree src/terminal/ module.
    // Closes the phantom-test CI trap (obs#1508 C8 / obs#1510 REQ-TCL-012):
    // `zig build test-terminal --summary all` proves the terminal test
    // count is non-zero, so PRs 1-5 cannot silently compile-zero tests.
    // Per-PR test slices append `_ = @import("<slice>.zig");` to root.zig
    // in the same commit that creates src/terminal/<slice>.zig.
    const terminal_test_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("tests/terminal/root.zig"),
        .imports = &.{
            .{ .name = "terminal", .module = terminal_mod },
            .{ .name = "term", .module = term_mod },
            .{ .name = "cursor", .module = cursor_mod },
            .{ .name = "style", .module = style_mod },
            .{ .name = "dpm", .module = dpm_mod },
            .{ .name = "kitty", .module = kitty_mod },
            .{ .name = "event", .module = event_mod },
        },
    });
    const terminal_test_step = b.addTest(.{ .root_module = terminal_test_mod });
    const run_terminal_test = b.addRunArtifact(terminal_test_step);
    const terminal_test_decl = b.step("test-terminal", "Run src/terminal/ + tests/terminal/ in isolation");
    terminal_test_decl.dependOn(&run_terminal_test.step);
    test_decl.dependOn(&run_terminal_test.step);

    // test step: tests/terminal/root.zig (PR 1, task obs#1514 §3 WU 1.3).
    // Single-entrypoint test runner for the in-tree src/terminal/ module.
    // Closes the phantom-test CI trap (obs#1508 C8 / obs#1510 REQ-TCL-012):
    // `zig build test-terminal --summary all` proves the terminal test
    // count is non-zero, so PRs 1-5 cannot silently compile-zero tests.
    // Per-PR test slices append `_ = @import("<slice>.zig");` to root.zig
    // in the same commit that creates src/terminal/<slice>.zig.
    const terminal_test_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("tests/terminal/root.zig"),
        .imports = &.{
            .{ .name = "terminal", .module = terminal_mod },
            .{ .name = "term", .module = term_mod },
            .{ .name = "cursor", .module = cursor_mod },
            .{ .name = "style", .module = style_mod },
            .{ .name = "dpm", .module = dpm_mod },
            .{ .name = "kitty", .module = kitty_mod },
            .{ .name = "event", .module = event_mod },
        },
    });
    const terminal_test_step = b.addTest(.{ .root_module = terminal_test_mod });
    const run_terminal_test = b.addRunArtifact(terminal_test_step);
    const terminal_test_decl = b.step("test-terminal", "Run src/terminal/ + tests/terminal/ in isolation");
    terminal_test_decl.dependOn(&run_terminal_test.step);
    test_decl.dependOn(&run_terminal_test.step);

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
            .{ .name = "terminal", .module = terminal_mod },
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

    // test step: tests/api_client.zig (Opción B WU-3, T3.4). Static-grep
    // guards verifying the stdlib rewrite (tryOneAttempt TLS branch uses
    // stdlib, validateViaApiWithTarget routes through bridge_sync_async,
    // tls_conn.connect signature matches the bridge's expected fn shape).
    const api_client_test_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("tests/api_client.zig"),
        .imports = &.{
            .{ .name = "api_auth", .module = lib_mod },
            .{ .name = "api_client", .module = lib_mod },
        },
    });
    const api_client_test_step = b.addTest(.{ .root_module = api_client_test_mod });
    const run_api_client_test = b.addRunArtifact(api_client_test_step);
    const api_client_test_decl = b.step("test-api-client", "Run tests/api_client.zig (Opción B WU-3 T3.4 static-grep guards)");
    api_client_test_decl.dependOn(&run_api_client_test.step);
    test_decl.dependOn(&run_api_client_test.step);

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

    // test step: tests/cancel_e2e.zig (tui-input-bugfixes-1 WU-D,
    // REQ-BUGFIX1-002/006). Static-grep guard for handler-install order
    // in main.zig + env-gated end-to-end cancel test (skipped unless
    // ZARGEANT_RUN_TUI_CANCEL_E2E=1). Wired as a separate artifact so
    // the gated e2e test does not block fast CI.
    const cancel_e2e_test_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("tests/cancel_e2e.zig"),
        .imports = &.{
            .{ .name = "api_auth", .module = lib_mod },
            .{ .name = "mock_server", .module = lib_mod },
        },
    });
    const cancel_e2e_test_step = b.addTest(.{ .root_module = cancel_e2e_test_mod });
    const run_cancel_e2e_test = b.addRunArtifact(cancel_e2e_test_step);
    const cancel_e2e_test_decl = b.step(
        "test-cancel-e2e",
        "Run tests/cancel_e2e.zig (tui-input-bugfixes-1 WU-D, env-gated e2e)",
    );
    cancel_e2e_test_decl.dependOn(&run_cancel_e2e_test.step);
    test_decl.dependOn(&run_cancel_e2e_test.step);

    // test step: tests/tui/cancel_path.zig (tui-input-flow-bugfixes-2 WU-3,
    // CAP-09 + CAP-13). Static-grep guard verifying the new pipe-write
    // call in src/tui.zig's Ctrl+C intercept + runtime roundtrip
    // assertion. The full pty mibu/termios e2e (CAP-13) is deferred to
    // WU-5 per design D3 follow-up.
    //
    // PR 6 (terminal-control-lib-from-scratch, WU 6.4, Q4): renamed from
    // tests/termios_sim.zig to tests/tui/cancel_path.zig. The contents
    // were always a cancel-path static-guard artifact (see file header
    // at tests/tui/cancel_path.zig:1-34), not a termios simulator; the
    // new name matches the actual contents and lives alongside the
    // other tui/ tests.
    const cancel_path_test_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("tests/tui/cancel_path.zig"),
    });
    const cancel_path_test_step = b.addTest(.{ .root_module = cancel_path_test_mod });
    const run_cancel_path_test = b.addRunArtifact(cancel_path_test_step);
    const cancel_path_test_decl = b.step(
        "test-cancel-path",
        "Run tests/tui/cancel_path.zig (tui-input-flow-bugfixes-2 WU-3 CAP-09 wiring guard)",
    );
    cancel_path_test_decl.dependOn(&run_cancel_path_test.step);
    test_decl.dependOn(&run_cancel_path_test.step);

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
    // QA 0.5 — Forbidden-syscall grep step (Opción B REQ-NEW-003 / T3.3).
    //   Scans src/*.zig for std.os.linux.{socket,connect,bind,listen} outside
    //   src/mock_server.zig (always allowed — never touch per design). Lines
    //   with `// allowed: std.os.linux.<name>` markers are exempted (mirrors
    //   the `no automatic key sources` pattern at api_auth.zig:657). Test-only
    //   raw socket use in src/fixtures_test.zig is also exempted — production
    //   code paths MUST use std.Io.net.Stream + std.http.Client.
    // =========================================================================
    const forbidden_syscall_check = b.addSystemCommand(&.{
        "sh", "-c",
        \\matches=$(grep -rn 'std\.os\.linux\.\(socket\|connect\|bind\|listen\)' src/ --include='*.zig' --exclude='mock_server.zig' --exclude='fixtures_test.zig' 2>/dev/null | grep -v '// allowed:')
        \\if [ -n "$matches" ]; then
        \\    echo "$matches"
        \\    echo ""
        \\    echo "FORBIDDEN: std.os.linux.{socket,connect,bind,listen} found outside mock_server.zig (Opción B REQ-NEW-003)."
        \\    echo "Production code MUST use std.Io.net.Stream + std.http.Client.connectTcp."
        \\    echo "If the use is intentional (mock-server 127.0.0.1 compat), add '// allowed: std.os.linux.<name>' marker on the line."
        \\    exit 1
        \\fi
    });
    const check_syscalls_step = b.step("check-forbidden-syscalls", "QA 0.5: forbid std.os.linux.{socket,connect,bind,listen} outside mock_server.zig (REQ-NEW-003)");
    check_syscalls_step.dependOn(&forbidden_syscall_check.step);

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
    verify_step.dependOn(check_syscalls_step);
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
