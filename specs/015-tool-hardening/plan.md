# Implementation Plan: [Lane C] Tool hardening — confinement, structured errors, edit modes, dir search

**Branch**: `015-tool-hardening` | **Spec**: `specs/015-tool-hardening/spec.md` | **Issue**: #18

## Summary

Four tool-layer hardenings: (1) path confinement for all file-touching tools (lexical `..`/absolute checks + realpath symlink detection) returning structured refusals, (2) executor propagation of `ToolResult.error_message` into the conversation, (3) `edit_file` create/delete modes, (4) `search_file` recursive directory search with a file-count bound.

## Technical Context

- Zig 0.15.2, zero deps; tests via `zig build test` (profile: full suite per red/green).
- Tools depend only on the `Fs` vtable (DI, constitution Principle II); fakes (`FakeFs`) used in tests.
- Executor `dispatch` loop (executor.zig ~L513) currently appends `res.output` (empty on failure) as the tool message — the propagation site.
- `Fs` vtable has no realpath; symlink escapes are undetectable today.

## Technical Decisions

### D1 — Confinement as a pure seam + one Fs addition
New `src/tool/confine.zig`: `check(alloc, fs, path) ?[]u8` returns a refusal message or null. Checks in order: (a) lexical — normalize `/`-components, `..` popping above the top is an escape; (b) absolute paths must be under `fs.cwd()`; (c) `~/` home shorthand is refused for tools (workspace-relative policy wins over FR-001's tilde convenience; `expandTilde` itself stays for non-tool Fs users — recorded tension); (d) realpath — when the path (or, for writes, its parent) exists, `fs.realpath` must land under `fs.cwd()`. `Fs.VTable` gains `realpath` (RealFs: `std.fs.cwd().realpathAlloc` on the resolved path, `error.FileNotFound` when absent → check skipped, lexical verdict stands; FakeFs: lexical `cwd_path` join — no symlinks in the fake). All four file tools call `confine.check` first and return `{ ok=false, error_message="confined: …" }`.

### D2 — Error propagation at the single dispatch site
executor.zig tool-message append becomes `.content = if (res.ok) res.output else try std.fmt.allocPrint(a, "error: {s}", .{res.error_message orelse "tool failed"})`. Unknown-tool path already produces an error_message, so it flows through the same site. No other executor behavior changes (keeps the Lane C conflict surface minimal per the issue).

### D3 — Edit modes via optional `mode` field
`edit_file` args keep `path` + `old`/`new`; new optional `mode` (`"replace"` default | `"create"` | `"delete"`). create: existing → structured error (no clobber), missing → file created with `new` content. delete: existing → removed, missing → structured error. Replace mode unchanged (file must exist, exactly-one match).

### D4 — Directory search via `dir` + `max_files`
`search_file` gains optional `dir` (recursive; takes precedence over `path`) and `max_files` (default 256, hard cap). Walks via `fs.readDir` recursively, classifies entries by "has children → dir else file" (FakeFs semantics; RealFs readDir failure → skip entry), formats `path:line: text` per match. Bound counts files opened, aborts the walk at the cap with a notice line.

## Data Flow

`Tool.execute(args_json)` → `confine.check(fs.cwd(), path)` → refusal | proceed → Fs vtable op → `ToolResult` → executor dispatch → tool message (`output` | `error: …`) → provider.
