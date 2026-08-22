# Tasks: Goal Execution Loop

**Input**: Design documents from `/specs/006-goal-execution-loop/`
**Prerequisites**: `spec.md`, `plan.md`

**Tests**: Required — the constitution (TDD, Principle V) mandates tests FIRST.
The implementation was built test-first; the loop is exercised end-to-end with
`FakeProvider` + `FakeFs` and zero real provider/filesystem access.

**Organization**: Tasks grouped by user story (US1–US3 from spec.md).

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)

## Phase 1: Setup (Interface Wiring)

- [X] T001 Implement `GoalExecutor` depending only on `Provider`, `Tool`s,
  `GoalRepository`, and `Fs` interfaces (no concrete references) in
  `src/agent/executor.zig` (FR-001).

---

## Phase 2: User Story 1 — Drive a goal to completion (P1)

- [X] T002 [P] [US1] Test (RED) `GoalExecutor drives a goal to completion
  (FakeProvider + FakeFs)`: scripted transcript (read → edit → finish) ends
  `completed` with the expected tool calls and a summary, no human input. Then
  implement the iteration + conversation build + completion handling (FR-002,
  FR-003, FR-004, SC-001).
- [X] T003 [P] [US1] Test (RED) `GoalExecutor honours an explicit completion
  criterion`: criterion alone completes the goal (FR-004).

## Phase 3: User Story 2 — Stop on blocked / budget (P1)

- [X] T004 [P] [US2] Implement blocked → `blocked` + reason, and turn-budget
  exceeded → defined stopped status, terminating the loop (FR-005, FR-006,
  SC-002, SC-005). Transient failures are fed back, not fatal.
- [X] T005 [P] [US2] Test (RED) `GoalExecutor retries transient provider errors
  and still completes`: transient provider failures tolerated, recovery
  continues (FR-009).

## Phase 4: User Story 3 — Abort on demand (P2)

- [X] T006 [P] [US3] Implement external abort signal (the `/stop` file from the
  CLI dispatcher) → `aborted`, no further provider/tool calls (FR-007, FR-010).

---

## Phase 5: Polish & Cross-Cutting

- [X] T007 Implement unknown-tool refusal (feed back an error, never execute an
  unknown tool) and per-iteration progress recording for resume (FR-008, FR-010).
- [X] T008 Verify `zig build test` — executor tests pass; FR-001..FR-010 and
  SC-001..SC-005 satisfied; no infinite loop under adversarial provider behavior.

## Dependencies & Execution Order

- T001 (interface wiring) blocks all user stories.
- US1 (T002, T003), US2 (T004, T005), US3 (T006) build on T001; parallelizable.
- T007 (cross-cutting) + T008 (verification gate) last.

## Notes

- The loop composes specs 002/003/004/005; it adds only orchestration.
- `FakeProvider` + `FakeFs` drive the full loop with zero real backend, proving
  SC-003.
