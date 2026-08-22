# Tasks: Goal State & Persistence

**Input**: Design documents from `/specs/005-goal-state-persistence/`
**Prerequisites**: `spec.md`, `plan.md`

**Tests**: Required — the constitution (TDD, Principle V) mandates tests FIRST.
The implementation was built test-first; the entity, state machine, and store
each ship with an independent test, no provider/agent dependency.

**Organization**: Tasks grouped by user story (US1–US3 from spec.md).

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)

## Phase 1: Setup (Shared Model)

- [X] T001 Define the `Goal` entity (objective, criterion, status, progress,
  budgets, timestamps, session, summary) and the `Status` enum + json helpers in
  `src/goal/goal.zig` (FR-001, FR-002).

---

## Phase 2: User Story 1 — Define and track a goal (P1)

- [X] T002 [P] [US1] Test (RED) `Goal.init builds a goal`: assert initial
  `active` status, set timestamps, and that a progress update bumps
  `last_updated`. Then implement the entity (FR-003).

## Phase 3: User Story 2 — Transition the lifecycle (P1)

- [X] T003 [P] [US2] Test (RED) `Status json round-trip` + transition validation:
  legal moves (active→completed/blocked/aborted, blocked→active) succeed; an
  illegal move (aborted→completed) is rejected with state unchanged. Then
  implement the state machine (FR-004, FR-005).

## Phase 4: User Story 3 — Persist and resume (P1)

- [X] T004 [P] [US3] Test (RED) `FsGoalRepository round-trip and isolation`:
  persist a partially progressed goal, reload in a fresh instance, assert exact
  match + resume; assert per-session isolation and corrupt-entry error. Then
  implement `repository.zig` over the `Fs` interface (FR-006..FR-010).

---

## Phase 5: Polish & Cross-Cutting

- [X] T005 Verify `zig build test` — goal + repository tests pass; FR-001..FR-010
  and SC-001..SC-005 satisfied; no provider/agent dependency.

## Dependencies & Execution Order

- T001 (entity + status) blocks all user stories.
- US1 (T002), US2 (T003), US3 (T004) build on T001; independent files → parallel.
- T005 is the final verification gate.

## Notes

- The store is behind a `GoalRepository` interface over `Fs`, so tests use a real
  temp dir with no live backend.
- "Resume" here means the state survives and reloads; driving transitions during
  a live run is spec 006.
