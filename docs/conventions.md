# Conventions

Project-wide conventions for the zargeant codebase. New entries MUST cite
the originating bug or design decision; this file is not a wish list.

---

## State storage — never alias stack-local buffers

**Rule.** A field on a long-lived state struct MUST NOT hold a `[]const u8`
(or `[]u8`, `[]const T`) slice that aliases a stack-local buffer declared
inside a function that has already returned. For short user-facing strings,
inline the data as a fixed-size buffer + length counter. For longer strings
or unbounded data, document the allocator that owns the memory.

**Why.** When a function returns, its stack frame is reclaimed. Any slice
that aliases a stack-local buffer becomes a dangling pointer. The next
function call can overwrite the bytes that the slice still claims to point
at, and the renderer / consumer reads garbage. This is a use-after-free
class of bug that Zig does NOT detect at compile time or at runtime in
safe modes (no ASan by default in `zig build`).

**Originating incident.** Bug 1 of the
`tui-input-flow-bugfixes-2` cycle (2026-09-01). `submitKeyEntry` and
`submitUnlock` (then at `src/modal.zig:381-394` and `:472-494`) declared
`var buf: [64]u8 = undefined;` inside the catch block, formatted the
error message via `std.fmt.bufPrint(&buf, ...)`, and stored the resulting
slice in `state.*.err_msg`. The slice dangles when the catch block
returns. `drawKeyEntry` (`:346-355`) and `drawUnlock` (`:427-436`)
read through the dangling pointer on the next render cycle and observed
whatever happened to live at the old stack slot. Reproduced as
"Enter does nothing on validation failure" — the error message was never
rendered, because by the time the renderer ran, the slice was pointing
at stale stack memory.

The same Bug 1 pattern was confirmed for `ErrorModalState.message`
(src/modal.zig:254) and the `openErrorModal` callers at :755, and
dissolved uniformly in WU-1.

**Pattern (BAD) — slice aliases stack-local buffer.**

```zig
var buf: [128]u8 = undefined;
const msg = std.fmt.bufPrint(&buf, "API rejected key: {s}", .{
    @errorName(err),
}) catch "API rejected key";
state.err_msg = msg; // SLICE DANGLES when this function returns
```

**Pattern (GOOD) — inline buffer + length counter on the state struct.**

```zig
state.err_msg_len = std.fmt.bufPrint(
    &state.err_msg_buf,
    "API rejected key: {s}",
    .{ @errorName(err) },
) catch std.fmt.bufPrint(
    &state.err_msg_buf,
    "API rejected key",
    .{},
) catch 0;
// state.err_msg_buf lives in the state struct; no dangle
```

The renderer iterates `state.err_msg_buf[0..state.err_msg_len]`.

**When this applies.**

- Every state field that holds a user-facing string and survives a function
  return boundary.
- Structs that the TUI or any long-lived consumer reads on subsequent
  frames / poll iterations.

**Where the inline convention is already applied** (post-WU-1, 2026-09-01):

- `KeyEntryState.err_msg_buf: [128]u8` + `err_msg_len: usize`
  (src/modal.zig:222-224).
- `UnlockState.err_msg_buf: [128]u8` + `err_msg_len: usize`
  (src/modal.zig:237-239).
- `ErrorModalState.message_buf: [128]u8` + `message_len: usize`
  (src/modal.zig:275-277).
- `Event.ValidateApiReply.err: [128]u8` + `err_len: usize` (channels.zig).
  The reply channel carries the error string inline; the worker does not
  pass a slice through.

**When this does NOT apply.**

- Short synchronous logs whose slice is consumed by `logger.global().log`
  before the function returns. The slice's lifetime ends inside the call;
  no aliasing hazard. Example: `src/modal.zig:598-601` (logger call).
  Annotate with a `ponytail:` comment if the pattern is non-obvious.
- Strings owned by an allocator with documented ownership transfer
  (e.g., `allocator.dupe(...)` whose result is later freed). These are
  not stack-local and follow the standard Zig allocator rules.
- Compile-time string literals (`"some literal"`), which are stored in
  the binary's read-only data segment and never dangle.

**Review checklist.** When reviewing a PR that adds or modifies a state
struct field:

1. Is the field a slice (`[]const u8`, `[]u8`, `[]const T`) or an inline
   buffer (`[N]u8` + `usize` length)?
2. If a slice: trace the producer function. Does the slice alias a
   `var buf: [N]u8 = undefined` declared inside that function? If yes,
   the bug is present. Refactor to inline.
3. If a slice: is the lifetime documented in a comment? Is the allocator
   that owns the memory unambiguous at the read site?
4. If an inline buffer: is the `*_len` field updated wherever `*_buf` is
   written? Is the default value (`.{0} ** N`, `0`) safe to render
   (i.e., `*_len == 0` short-circuits the renderer)?

**How this maps to tests.**

- `src/modal.zig` in-file layout test (CAP-12): asserts
  `@hasField(KeyEntryState, "err_msg_buf")` and
  `!@hasField(KeyEntryState, "err_msg")` (and mirrors for `UnlockState`
  and `ErrorModalState`).
- `tests/termios_sim.zig` static guards verify the architecture that
  makes the inline convention enforceable (no SIGINT bridge, no
  `watchCancelPipe`).

**Forward-port (open).** `AgentLoopState.cumulative` (the SSE message
list) is allocator-owned (the runtime allocator), so this convention
does not apply. If a future contributor adds a *new* state struct that
holds a short user-facing string, apply this convention preemptively
rather than waiting for a Bug 1 duplicate.