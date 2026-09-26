# AGENTS.md — Tiger Style Guidelines for Zig

This document specifies the strict coding conventions, architecture constraints, and defensive programming standards required when generating or modifying Zig code in this project. All AI agents and human contributors must adhere to these rules without exception.

---

## 1. Core Engineering Philosophy

1. **Fail Fast & Explicitly**: An incorrect assertion failure in dev/prod is better than silent corruption. Crash immediately if an invariant is violated.
2. **Zero Hot-Path Allocation**: Allocate all memory upfront during system startup. Never perform dynamic allocations (`allocator.alloc`, `allocator.create`) in event loops, request handlers, or hot paths.
3. **Bounded & Deterministic Execution**: Bounded loops, static array capacities, and fully deterministic execution paths. No recursion. No hidden dynamic growth.
4. **Hardware-Aware Design**: Prioritize contiguous memory layouts, CPU cache alignment, explicit struct field padding, and memory safety over high-level abstractions.

---

## 2. Naming & Style Conventions

Follow standard Zig naming patterns strictly:

- **Types / Structs / Enums / Unions**: `PascalCase` (e.g., `MessageBuffer`, `StateEngine`)
- **Functions / Methods**: `camelCase` (e.g., `init`, `processPacket`, `validateHeader`)
- **Variables / Struct Fields / Constants**: `snake_case` (e.g., `max_connections`, `head_index`, `payload_len`)
- **Namespaces / Modules**: `snake_case` (e.g., `const storage = @import("storage.zig");`)

---

## 3. Memory & Lifetime Management

- **Static Allocation First**:
    - Pass slice capacities and array bounds at compile-time (`comptime`) or system startup.
    - Prefer `[CAPACITY]T` over dynamic arrays where maximum limits are known.
- **Allocator Passing**:
    - If an allocator is required, pass `allocator: std.mem.Allocator` explicitly to `init()` or startup routines.
    - **Forbidden**: Storing allocators in hot-path sub-components or calling allocation routines inside execution loops.
- **Explicit Slices**: Always work with bounded slices `[]T` or `[]const T` and assert their lengths before indexing.

```zig
// GOOD: Explicit fixed capacity, static buffer passed from parent
pub const RingBuffer = struct {
    buffer: []u8,
    head: usize = 0,
    tail: usize = 0,

    pub fn init(memory: []u8) RingBuffer {
        std.debug.assert(memory.len > 0);
        return .{ .buffer = memory };
    }
};

// BAD: Dynamic allocation inside processing logic
pub fn processInput(allocator: std.mem.Allocator, data: []const u8) !void {
    var list = std.ArrayList(u8).init(allocator); // FORBIDDEN in hot paths
    defer list.deinit();
}
```

---

## 4. Defensive Programming & Assertions

Assertions are mandatory contracts. They document pre-conditions, post-conditions, and system invariants.

- **Mandatory Assertion Usage**:
    - Check pointer non-nullability (if raw pointers are used).
    - Check index boundaries and slice lengths.
    - Check valid enum ranges and state flags.
- **Safeguard Casts**: Never perform type narrowing (`@intCast`, `@ptrCast`) without asserting the range first.

```zig
pub fn getItem(self: *const Container, index: usize) *const Item {
    // Assert preconditions explicitly
    std.debug.assert(index < self.items_count);
    std.debug.assert(self.items_count <= self.items.len);

    return &self.items[index];
}

pub fn safeTruncate(value: u64) u32 {
    std.debug.assert(value <= std.math.maxInt(u32));
    return @intCast(value);
}
```

---

## 5. Control Flow & Bounded Loops

- **No Infinite Loops**: Avoid unconstrained `while (true)` loops unless explicitly servicing a top-level shutdown signal in a dedicated thread loop.
- **Bounded Iteration**: Every loop must have a clear upper bound or termination invariant.
- **Exhaustive Switches**: Never use `else` pragma in `switch` statements over enums/error sets unless absolutely necessary. Force compile-time safety when new enum variants are added.
- **No Recursion**: Stack size must remain predictable and bounded. Use explicit stacks or iterative state machines instead.

```zig
// GOOD: Exhaustive enum handling
const State = enum { idle, processing, completed };

pub fn handle(state: State) void {
    switch (state) {
        .idle => prepare(),
        .processing => execute(),
        .completed => cleanup(),
    } // Adding a new State variant will force a compilation error here.
}
```

---

## 6. Error Handling

- **Explicit Error Sets**: Define domain-specific error sets rather than generic `anyerror`.
- **No Swallowing Errors**: Never ignore return errors with `_ = try ...` or catch-all blocks unless explicitly documented with a code comment explaining why the error is unrecoverable or harmless.
- **Fail-Fast Error Propagation**: Use `try` to bubble up operational errors, or panic/assert on internal logic bugs.

```zig
pub const StorageError = error{
    DiskFull,
    ChecksumMismatch,
    CorruptedHeader,
};

pub fn readSector(sector_id: u64) StorageError!Sector {
    std.debug.assert(sector_id < MAX_SECTORS);
    // ...
}
```

---

## 7. Determinism & Testability

To support deterministic simulation (Fault Injection / VOPR testing):

1. **No Direct I/O or System Calls in Core Logic**: Decouple business logic and state transitions from OS syscalls, network sockets, or system timers.
2. **Inject Dependencies Explicitly**: Pass time (`now_ms: u64`), random seeds/generators (`prng: *std.rand.Random`), and network interfaces into functions or struct contexts.
3. **Pure Functions**: State updates must strictly be a function of `(CurrentState, Input) -> (NewState, Output)`.

```zig
// GOOD: Time is injected, making logic fully testable and deterministic
pub fn isExpired(self: *const Session, current_time_ms: u64) bool {
    std.debug.assert(current_time_ms >= self.created_at_ms);
    return (current_time_ms - self.created_at_ms) > SESSION_TIMEOUT_MS;
}

// BAD: Calling system clock directly inside core logic
pub fn isExpiredBad(self: *const Session) bool {
    const now = std.time.milliTimestamp(); // Non-deterministic!
    return (now - self.created_at_ms) > SESSION_TIMEOUT_MS;
}
```

---

## 8. Agent Checklist (Run before finishing task)

Before delivering any Zig code changes, verify that:

- [ ] `zig fmt` passes clean formatting.
- [ ] No `allocator.alloc` or dynamic heap allocation exists inside loops or request handlers.
- [ ] Every function validates its input arguments using `std.debug.assert`.
- [ ] `@intCast` or cast operations are preceded by explicit range assertions.
- [ ] All `switch` statements on enums are exhaustive (no lazy `else =>`).
- [ ] All loops are bounded and recursion is completely avoided.
- [ ] System clock or PRNGs are passed in as parameters rather than called directly inside logic.

---

## 9. Task Runner (`justfile`)

The project uses [`just`](https://github.com/casey/just) as a thin wrapper over the most common Zargeant workflows (see [`justfile`](./justfile)). **Always prefer `just <recipe>` over memorized raw `zig build ...` invocations** — recipes are the discoverable surface for the whole team.

### 9.1 Quick reference

| Category | Recipe                    | What it does                                                                   |
| -------- | ------------------------- | ------------------------------------------------------------------------------ |
| Meta     | `just`                    | Default. Lists all recipes.                                                    |
| Meta     | `just help`               | Show `just`'s CLI help.                                                        |
| Build    | `just build`              | `zig build` — debug binary, fastest iteration.                                 |
| Build    | `just build-safe`         | `zig build -Doptimize=ReleaseSafe` — production parity without LTO.            |
| Build    | `just build-fast`         | `zig build -Doptimize=ReleaseFast` — fully optimized.                         |
| Build    | `just clean`              | Wipe `.zig-cache` + `zig-out`.                                                 |
| Run      | `just run -- <args>`      | Run production binary with forwarded args.                                     |
| Run      | `just run-mock`           | Run with `--mock` (offline, no real HTTP).                                     |
| Test     | `just test`               | Umbrella: all 7 individual `test-*` targets.                                   |
| Test     | `just test-terminal`      | `src/terminal/` + `tests/terminal/` in isolation.                              |
| Test     | `just test-tui`           | `tests/tui/terminal_smoke.zig` (public-surface compile guard).                 |
| Test     | `just test-runtime-thread` | `tests/tui/runtime_thread.zig` (PR1+PR1.5 TUI fix coverage).                  |
| Test     | `just test-api-client`    | `tests/api_client.zig` (REQ-NEW-003 socket guard).                             |
| Test     | `just test-tools`         | `tools/` in-file tests.                                                        |
| Test     | `just test-cancel-path`   | `tests/tui/cancel_path.zig` (CAP-09 wiring guard).                             |
| Test     | `just test-cancel-e2e`    | `tests/cancel_e2e.zig` (env-gated end-to-end cancel pipe).                     |
| Test     | `just test-embedded`      | `src/*.zig` embedded tests via standalone binary (see §9.2).                   |
| Test     | `just test-all`           | `just test` + `just test-embedded`.                                           |
| QA       | `just verify`             | `zig build verify` (QA 0..6, compile-first in 3 optimization modes).          |
| QA       | `just fmt-check`          | `zig build check` (QA 0 — fmt + AST check).                                   |
| QA       | `just fmt`                | `zig fmt src/ tests/ tools/` (auto-format in place).                          |
| QA       | `just check-syscalls`     | QA 0.5 — REQ-NEW-003 forbidden syscall guard.                                 |
| QA       | `just check-tdd`          | Every `src/*.zig` must have ≥ 1 `test` block.                                 |
| QA       | `just check-coauthor`     | No `Co-Authored-By: ...AI...` lines in commits ahead of main.                  |
| QA       | `just check`              | Umbrella: `fmt-check + check-syscalls + check-tdd + check-coauthor`.           |
| CI       | `just ci`                 | Full local CI via Podman (Alpine + Zig 0.16.0, `--rm`, no garbage).            |
| CI       | `just ci-fast`            | Local CI skipping the heavy build steps (static guards only).                  |
| CI       | `just ci-rebuild`         | Local CI wiping `~/.cache/zargeant-podman-ci/` first.                          |
| CI       | `just ci-rebuild-image`   | Local CI rebuilding the Alpine container image from scratch.                   |
| CI       | `just ci-shell`           | Drop into the CI container shell for debugging.                               |
| CI       | `just ci-clean`           | Wipe CI image + cache (full reset).                                            |
| Git      | `just git-status`         | Working tree short status + ahead/behind main.                                 |
| Git      | `just git-log`            | `git log --oneline` of commits ahead of `origin/main`.                         |
| Helpers  | `just odd`                | List ODD feature docs in `odd/tasks/`.                                         |

```bash
just                # list all recipes (default)
just --help         # just's own CLI help
just -u <recipe>    # show inline docs for one recipe
```

### 9.2 Test recipe conventions — avoid `zig build test`

The test recipes **deliberately do not** invoke the umbrella `zig build test` target. Zig 0.16.0 has a reproducible hang in `std.zig.Server`'s `--listen=-` IPC protocol on non-CI environments (agent shell without TTY, Podman containers): the child test binary exits cleanly after `cancel_e2e` CAP-09 passes, but the parent `zig` process never receives the completion message and waits indefinitely.

Workarounds attempted (all reproduced the hang):

- Disabling `cancel_e2e` via `ZARGEANT_RUN_TUI_CANCEL_E2E=0` — still hangs.
- Forcing a TTY allocation (`podman run -t`) — still hangs.
- Running the cached test binary directly in standalone mode — separate hang location.

**Decision**: each `test-*` recipe invokes a single `zig build test-<name>` target (compiled into one binary that runs independently). The ~197 `src/*.zig` embedded tests not covered by any individual target are deferred to GitHub Actions CI when minutes are available; `just test-embedded` includes a best-effort workaround for local coverage.

### 9.3 Local CI container (Podman, Alpine)

The `ci*` recipes wrap [`tools/local-ci.sh`](./tools/local-ci.sh), which orchestrates a one-shot Podman container built from [`tools/zargeant-ci.Containerfile`](./tools/zargeant-ci.Containerfile).

| Property        | Value                                                                  |
| --------------- | ---------------------------------------------------------------------- |
| Base image      | `docker.io/library/alpine:3.20` (musl libc, ~8 MB)                    |
| Runtime stack   | Zig 0.16.0 (glibc-linked) + `git` + `curl` + `bash` + `gcompat`        |
| `gcompat`       | Glibc compat layer required because Zig's x86_64-linux tarball is glibc-linked; bridges it onto musl. |
| Container flags | `--rm` on every invocation → zero leftover containers                  |
| Cache           | `~/.cache/zargeant-podman-ci/` (persistent `.zig-cache` between runs) |
| Image tag       | `localhost/zargeant-ci:latest` (398 MB, baked once, reused across runs) |
| Build context   | Project root (so `zig build` can find `src/`, `build.zig`, etc.)       |

### 9.4 When adding new workflows

Prefer a new recipe in [`justfile`](./justfile) over memorizing a long raw command. Keep the recipe name + one-line description as the discoverable surface; if a recipe has non-obvious behavior (timeouts, env vars, workarounds), add a short comment block immediately above it.

---

## 10. Pre-Merge QA Gate Ordering (Learn from history)

**Rule**: Run QA gates in this order before any merge to `main` or release:

1. **Builds** — `just build` + `just build-safe` + `just build-fast` (must all succeed)
2. **Check** — `just check` (QA 0..5 static guards: fmt, syscalls, TDD, co-author)
3. **test-all** — `just test-all` (umbrella test targets + embedded workaround)
4. **verify** — `just verify` (3-mode compile + comprehensive QA gamut)
5. **ci** — `just ci` (independent Podman Alpine + Zig 0.16.0 verification)

**Rationale (learned the hard way — see obs#1788 session closure + Phase 2 blocker)**:

- **Builds FIRST**: A green test suite + clean static guards + passing CI means nothing if the production binary doesn't compile. Without a buildable binary there is no software to ship. Tests build into separate `test-*` targets with their own module wiring; they do **not** validate the production binary's module graph. The build gate is the only one that proves the artifact exists and runs.
- **Check second**: Cheap (~1 sec), no compile, runs after build to catch style/architecture issues on already-compiled artifacts. Independent of test results.
- **test-all third**: Exercises the built binary's behavior on the host. Depends on build artifacts being present in `.zig-cache`.
- **verify fourth**: 3-mode compile + comprehensive QA gamut. Includes its own test runs, so placing it after `test-all` gives a fail-fast signal before paying the 3-mode compile cost.
- **ci LAST**: Independent verification via Podman container (different env, clean cache). Slowest (~5–7 min) but most authoritative — only env-isolated check.

**Forbidden shortcuts**:

- ❌ **Skip builds and rely on tests passing** — tests build into separate `test-*` targets with isolated module wiring. A bug like `exe_mod` missing an `addImport` for a new module passes every test target yet the production binary fails to compile. Phase 2 (slices 1–4) shipped with this exact gap; the bug was caught only because the user asked for a pre-merge `just build` gate.
- ❌ **Skip ci and merge based on local Podman only** — `just ci` is the only independent verification (different container, different cache state, different mount). Local results do not prove the artifact builds in a clean environment.
- ❌ **Skip verify because ci already passed** — `verify` includes 3-mode compile (Debug + ReleaseSafe + ReleaseFast). Optimization-specific bugs only surface in `ReleaseSafe`/`ReleaseFast`. `ci` skips these (see `tools/local-ci.sh` `--skip-build` flag).

**Embedded tests caveat**: Per §9.2, `just test-embedded` is best-effort due to Zig 0.16 `std.zig.Server` `--listen=-` IPC hang. Embedded test results may be incomplete on local runs; defer to GitHub Actions when CI minutes return.

