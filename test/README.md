# `test/` — Build include path + recorded fixtures

This directory is the **build include path** for the test build module. It is
referenced from `build.zig` via `test_mod.addIncludePath(b.path("test"))` and
exists to host fixture files that the test suite reads at compile/test time.

## Layout

```
test/
└── fixtures/                    ← C-include / Zig-loadable data files
    └── minimax_stream.jsonl     ← recorded OpenAI-style SSE chat completion
```

The `tests/` (plural) directory holds actual Zig test source files
(`api_client.zig`, `cancel_e2e.zig`, `terminal/`, `tui/`) — those are
the test sources themselves. `test/` (singular) holds only fixtures and
include data.

## Invariant: no real API keys

Any file in `test/fixtures/` **must not** contain a real API key. This is
enforced by `src/fixtures_test.zig` (a unit test that scans the directory
and fails on any `eyJ`-prefixed JWT or known key prefix).

If a recorded fixture looks like it could leak credentials:

1. Run `grep -E '"sk-[A-Za-z0-9_-]{20,}"' test/fixtures/` (real OpenAI keys)
2. Run `grep -E 'eyJ[A-Za-z0-9_-]{20,}\.' test/fixtures/` (JWT prefixes)
3. Replace any matches with `<REDACTED>` or the recorded equivalent.
4. Re-run `just test-tools` to confirm `src/fixtures_test.zig` still passes.

## Adding a new fixture

1. Drop the file under `test/fixtures/<name>.<ext>`.
2. Wire the load site in the consuming code
   (`std.Io.Dir.cwd().readFileAlloc(io, "test/fixtures/<name>", ...)`).
3. Run the full suite: `just test`.
4. Run the no-real-keys guard: `just test-tools` (this is the test that
   walks the fixtures directory and asserts cleanliness).

## Naming convention

Fixture filenames should describe **the format and purpose**, not the
generator that produced them. Avoid embedding model brand names in
filenames — historical exception: `minimax_stream.jsonl` was kept as
the canonical stream fixture and is referenced by name from
`src/fixtures_test.zig`. New fixtures should prefer neutral names like
`recorded_stream.jsonl` or `sse_chat_completion.jsonl`.

## Related

- `build.zig:165` — `test_mod.addIncludePath(b.path("test"))`
- `src/fixtures_test.zig` — no-real-keys invariant test (RED if violated)
- `tests/fixtures/` — separate fixtures used by Zig test sources directly
  (e.g. `ansi_injection.txt` for `tests/tui/` terminal tests)
