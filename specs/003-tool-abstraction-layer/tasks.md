# Tasks: Tool Abstraction Layer

**Input**: Design documents from `/specs/003-tool-abstraction-layer/`
**Prerequisites**: `spec.md`, `plan.md`

**Tests**: Required — the constitution (TDD, Principle V) mandates tests FIRST.
The implementation below was built test-first; every tool ships with an
independent test asserting correct behavior against a real temp directory or a
fake `Fs`.

**Organization**: Tasks grouped by user story (US1–US5 from spec.md).

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)

## Phase 1: Setup (Shared Interface)

- [X] T001 Define `Tool` vtable interface and `ToolResult` in `src/tool/tool.zig`
  (fields per spec.md FR-002/FR-003: `ctx`, `VTable{execute,schema,name}`,
  `ToolResult{ok,output,error_message}`)

---

## Phase 2: User Story 1 — Read a file (Priority P1)

- [X] T002 [P] [US1] Test (RED) `ReadTool reads via Fs`: known file content
  returned exactly; missing file yields a clear failure result. Then implement
  `read.zig` to satisfy it.

## Phase 3: User Story 2 — Edit a file (Priority P1)

- [X] T003 [P] [US2] Test (RED) `EditTool replaces exactly once`: create with
  content, replace a region, assert file + result; unapplicable edit leaves the
  file unchanged. Then implement `edit.zig` to satisfy it.

## Phase 4: User Story 3 — Search contents (Priority P1)

- [X] T004 [P] [US3] Test (RED) `SearchTool finds matching lines`: known
  substring at a known path/line; no-match returns empty success. Then implement
  `search.zig` to satisfy it.

## Phase 5: User Story 4 — Execute a command (Priority P1)

- [X] T005 [P] [US4] Test (RED) `BashTool runs a command`: `echo` → success with
  output; non-zero exit → failure carrying status, no crash. Then implement
  `bash.zig` to satisfy it (bounded output).

## Phase 6: User Story 5 — Injected interface (Priority P2)

- [X] T006 [P] [US5] Implement `Fs` interface + `RealFs` in `src/fs/fs.zig` and
  wire each tool's `init(fs)` so tools depend on `Fs`, not the filesystem.
- [X] T007 Verify a fake `Fs` + fake `Tool` drive the executor with zero real
  side effects (executor test).

---

## Phase 7: Polish & Cross-Cutting

- [X] T008 Run `zig build test` — all five tool tests (T002–T005) plus the
  executor test pass; FR-001..FR-010 and SC-001..SC-005 satisfied.

## Dependencies & Execution Order

- T001 (interface) blocks all user stories.
- US1–US4 are independent files → T002–T005 can run in parallel.
- US5 (T006–T007) depends on the `Fs` interface being in place.
- T008 is the final verification gate.

## Notes

- Every tool test is independent and asserts a structured `ToolResult`.
- No tool-specific logic exists above the `Tool` interface; the executor holds a
  `Tool` array and calls `execute` only (verified by the `FakeFs`/`FakeProvider`
  executor test).
- This layer is the prerequisite for spec 006 (goal execution loop).
