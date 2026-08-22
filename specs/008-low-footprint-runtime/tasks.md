# Tasks: Low-Footprint Multi-Window Runtime

**Input**: Design documents from `/specs/008-low-footprint-runtime/`
**Prerequisites**: `spec.md`, `plan.md`

**Tests**: Required — the constitution (TDD, Principle V) mandates tests FIRST.
For this system-level property the "test" is the `memory-harness.sh` measurement
procedure (FR-004, FR-005, FR-010), which is itself verified to run and assert.

**Organization**: Tasks grouped by user story (US1–US3 from spec.md).

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)

## Phase 1: Setup (Native Runtime)

- [X] T001 Deliver the native Zig binary (`build.zig` + `src/main.zig`) with
  explicit/manual allocators and no GC, so per-window memory is bounded by
  explicit allocations (FR-001, FR-003).

---

## Phase 2: User Story 1 — 20 windows within budget (P1)

- [X] T002 [P] [US1] Implement the memory measurement harness
  (`memory-harness.sh`) that launches N windows, waits for steady state, and
  asserts the total RSS against the budget, reporting a clear breach (FR-004,
  FR-005, FR-006, FR-009).
- [X] T003 [P] [US1] Verify 20 concurrent idle windows report total RSS ≤ the
  proxy budget (~1.25 GB), satisfying master spec SC-002 (SC-001).

## Phase 3: User Story 2 — A single idle window is tiny (P1)

- [X] T004 [P] [US2] Verify a single idle window has a small, bounded footprint
  that does not grow over an extended idle period (FR-002, FR-003, SC-002).

## Phase 4: User Story 3 — Repeatable harness (P2)

- [X] T005 [P] [US3] Verify the harness runs for several N (1, 5, 20), reports
  total + per-window memory, and flags a budget breach instead of passing silently
  (FR-004, FR-005, FR-008, SC-003, SC-004).
- [X] T006 [P] [US3] Verify the same harness run is repeatable and would flag a
  regression automatically (FR-010, SC-005).

---

## Phase 5: Polish & Cross-Cutting

- [X] T007 Document the bounded-active-memory design (streaming responses,
  single rolling transcript, per-goal budget) so totals meet the budget at steady
  state even with large inputs (FR-007).

## Dependencies & Execution Order

- T001 (native runtime) is the prerequisite for all measurement.
- US1 (T002, T003), US2 (T004), US3 (T005, T006) build on T001; the harness (T002)
  is shared across them.
- T007 (design note) + verification gate last.

## Notes

- The harness measures idle windows (the per-window floor). Active-goal steady-state
  cost is bounded by design (FR-007) and covered by the same total budget.
- Cosmetics/theming are explicitly out of scope (per the master spec).
