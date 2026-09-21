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
