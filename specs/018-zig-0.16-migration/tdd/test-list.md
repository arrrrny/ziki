# Test List — 018-zig-0.16-migration

Migration lane: the suite itself is the test list. Every existing test must keep its
intent and pass under 0.16.0; `compat.zig` adds env-access tests of its own.

| ID | Check | Status |
|----|-------|--------|
| A1 | `zig 0.16.0 build test` — full suite green (1 gated skip allowed) | DONE |
| A2 | `zig fmt --check src/ tests.zig build.zig` clean | DONE |
| U1 | compat env access (set → value, unset → null) | DONE |
