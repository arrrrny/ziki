# Test List — 015-tool-hardening

Profile: `.specify/memory/tdd-profile.md` (zig, full `zig build test` per check).

## Outer acceptance behaviors

| ID | Behavior (test name) | Trace | Status |
|----|----------------------|-------|--------|
| A1 | `confine refuses .. traversal and absolute paths outside the root (T1)` | FR-001, AS-1/2 | DONE |
| A2 | `confine detects a symlink escape via realpath and fails closed (T2)` | FR-001, AS-3 | DONE |
| A3 | `executor propagates a failed tool's error_message into the conversation (T4)` | FR-002, AS-1 | DONE |
| A4 | `edit_file create/delete modes (T5)` | FR-003, AS-1..3 | DONE |
| A5 | `search_file recursive dir search with file bound (T6)` | FR-004, AS-1/2 | DONE |

## Inner unit behaviors

| ID | Behavior (test name) | Trace | Status |
|----|----------------------|-------|--------|
| U1 | confine allows ordinary in-root relative and absolute-under-cwd paths | FR-001 | DONE |
| U2 | confined refusals carry the `confined:` prefix (structured, not crashes) | FR-001 | DONE |

Notes: no per-test runner (`single: null`) — suite-level red/green; compile-failing
tests are valid reds for new APIs.
