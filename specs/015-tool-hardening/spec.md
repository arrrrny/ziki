# Feature Specification: Tool hardening — confinement, structured errors, edit modes, dir search

**Feature Branch**: `015-tool-hardening` | **Issue**: [#18](https://github.com/arrrrny/ziki/issues/18) (Lane C) | **Created**: 2026-09-15

**Input**: Issue #18 verbatim tasks (audit baseline: spec 003 strict 20% — tools only cover happy paths).

## User Scenarios & Testing *(mandatory)*

### User Story 1 — Path confinement (P1)

All file-touching tools (read_file, edit_file, write_file, search_file) must refuse
paths escaping the workspace root — `..` traversal, absolute paths outside the root,
and symlinked escapes — returning a structured refusal instead of acting.

**Acceptance Scenarios**:

1. **Given** a tool call with `../outside.txt`, **When** executed, **Then** a structured `ok=false` refusal is returned and no file is touched.
2. **Given** an absolute path outside the workspace root, **When** executed, **Then** the same structured refusal.
3. **Given** a symlink inside the workspace pointing to a real file outside it, **When** a tool reads it, **Then** the escape is detected via realpath and refused (fail closed).

### User Story 2 — Structured tool errors (P2)

`ToolResult.error_message` is produced but discarded by the executor: failed tool
calls and unknown tools become empty assistant content. The error text must be
propagated into the conversation so the model can react.

**Acceptance Scenarios**:

1. **Given** a scripted provider whose tool call fails (unknown tool or tool error), **When** the turn completes, **Then** the next provider request contains a tool message carrying the error text (prefixed `error:`).

### User Story 3 — Edit create/delete modes (P2)

`EditTool` only replaces in existing files; add create-if-missing and delete-file
modes.

**Acceptance Scenarios**:

1. **Given** `mode:"create"` and a missing path, **When** executed, **Then** the file is created with `new` as content.
2. **Given** `mode:"create"` and an existing path, **When** executed, **Then** a structured error (no clobber).
3. **Given** `mode:"delete"` and an existing path, **When** executed, **Then** the file is removed; missing path → structured error.

### User Story 4 — Directory search (P3)

`SearchTool` matches single files only; add recursive directory search with a bounded
file count.

**Acceptance Scenarios**:

1. **Given** a directory tree and `dir` argument, **When** searched, **Then** matches from every file are returned as `path:line: text`.
2. **Given** more files than the bound, **When** searched, **Then** at most `max_files` files are examined (default bound applies when omitted).

## Requirements

- **FR-001**: File-touching tools MUST refuse (structured `ok=false`, message prefixed `confined:`) any path that lexically escapes the root (`..`), any absolute path not under the root, and any path whose realpath lands outside the root (symlink escape).
- **FR-002**: The executor MUST include a failed tool's `error_message` in the tool message content (`error: …`) instead of an empty string.
- **FR-003**: `edit_file` MUST support `mode:"create"` (create-if-missing, refuse existing) and `mode:"delete"` in addition to the default replace mode.
- **FR-004**: `search_file` MUST support a `dir` argument for recursive search, bounded by `max_files` (default 256).
- **FR-005**: The HTTP transport / provider code MUST NOT be modified (Lane C touches tools + one executor propagation site only).

## Success Criteria

- SC-001: `zig build test` green; confinement tests attempt escapes via `FakeFs` and a real tmpDir symlink and fail closed.
- SC-002: Every issue task has a failing-before/passing-after test.
