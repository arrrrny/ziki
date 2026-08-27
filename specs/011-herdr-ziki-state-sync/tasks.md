# Tasks: Herdr ↔ Ziki Agent-State Integration

**Input**: Design documents from `/specs/011-herdr-ziki-state-sync/`

**Prerequisites**: plan.md (required), spec.md (required for user stories), research.md, data-model.md, contracts/

**Tests**: This feature is built test-first (TDD). Test tasks are MANDATORY and
MUST precede their implementation task. Each test task carries a `[Bnn]` behavior
id from `tdd/test-list.md` and is ticked by `/skill:speckit-tdd.run`. Tests MUST
be observed failing before the implementation is written.

**Organization**: Tasks are grouped by user story (US1–US4) so each story is an
independently testable increment. US4 is a Herdr-side UI concern (cross-repo) and
requires no Ziki implementation beyond FR-001…FR-008.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (US1, US2, US3, US4)
- Include exact file paths in descriptions
- Behavior markers `[Ann]` / `[Unn]` bind a task to a behavior in `tdd/test-list.md`

## Path Conventions

- Single project: `src/` at repository root; `tests.zig` is the test aggregator.

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Register the new modules so the suite collects them.

- [x] T001 [P] Register `src/agent/state.zig` and `src/agent/herdr.zig` in `tests.zig` aggregator (`_ = state;` / `_ = herdr;` in `test "aggregator loads all modules"`) so `zig build test` collects their tests.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: The state model and publication primitives every story depends on.

- [x] T002 [P] Implement `AgentState` enum `{ idle, working, blocked }` with `toHerdr()` mapping to Herdr `AgentState` (`idle→Idle`, `working→Working`, `blocked→Blocked`) and an `Unknown` emission path in `src/agent/state.zig` [U1] [U2] (FR-001, FR-005).
- [x] T003 [P] Define `PaneReportParams` struct (pane_id, source, agent, state, message?, seq, agent_session_id?, agent_session_path?) and the `HerdrReporter` DI interface (`report(params) !void`) in `src/agent/state.zig` [U3] (FR-002).
- [x] T004 [P] Implement `StatePublisher` in `src/agent/state.zig`: `publish(state, message?)` increments a monotonic `seq`, pushes `PaneReportParams` via `HerdrReporter` (errors swallowed, never crashes), and emits the screen marker `[ziki-state: <state>]` + OSC title `\x1b]2;ziki:<state>\x07` to an injected `std.io.AnyWriter` [U3][U4][U5][U6][U7][U8][U9][U10] (FR-002, FR-003, FR-004, FR-007, FR-008).
- [x] T005 [P] Implement `HerdrHttpClient` in `src/agent/herdr.zig`: POSTs JSON `PaneReportParams` to `${HERDR_API_URL}/api/v1/pane/report/agent` (default `http://localhost:7878`) over the existing `Transport` interface, with `source="herdr:ziki"`, `agent="ziki"` [U11][U12] (FR-002, contract §2).
- [x] T006 [P] Implement `FakeHerdrReporter` (records published params; can be forced to fail) in `src/agent/herdr.zig` as the test double [U13] (DI, mirrors `FakeProvider`).

---

## Phase 3: User Story 1 (P1) — Forklift coordinates Ziki panes by live state

**Goal**: Herdr reports each Ziki pane's state (working/blocked/idle) without transcript scraping.
**Independent Test**: drive a goal through a blocked point and confirm `herdr agent explain <pane>` reports `blocked`, `working` while executing, `idle` when ended.

- [x] T007 [US1] Write FAILING tests for `AgentState`→Herdr mapping and `PaneReportParams` field correctness in `src/agent/state.zig` [U1][U2][U3] (FR-001, FR-002, FR-005).
- [x] T008 [US1] Write FAILING tests for `StatePublisher.publish` emitting correct `PaneReportParams` (pane_id, source, agent, state, monotonic seq, session id/path) and screen marker + OSC, using `FakeHerdrReporter` + a capturing `std.io.AnyWriter`, in `src/agent/state.zig` [U3][U4][U5][U6][U7] (FR-002, FR-003, FR-004, SC-006).
- [x] T009 [US1] Write FAILING tests for degrade path: `reporter = null` (no `HERDR_PANE_ID`) still emits screen marker + OSC and never crashes; reporter error is swallowed [U8][U9] (FR-008).
- [x] T010 [US1] Make T007–T009 green by completing T002–T006 (state model, `StatePublisher`, `HerdrHttpClient`, `FakeHerdrReporter`) in `src/agent/state.zig` + `src/agent/herdr.zig` [U1][U2][U3][U4][U5][U6][U7][U8][U9][U10][U13] (FR-001, FR-002, FR-003, FR-004, FR-005, FR-007, FR-008).
- [x] T011 [US1] Wire `main.zig` `runGoal` to read `HERDR_PANE_ID` / `HERDR_API_URL`, build `StatePublisher` (reporter=null when pane id absent), set `session_id`/`session_path` from the `Goal`, and pass it into `GoalExecutor` [U19] (FR-008).
- [x] T012 [US1] Add optional `publisher: ?StatePublisher = null` to `GoalExecutor` and call `publish` at each `goal.status` transition (working at start; blocked/completed/aborted terminal) with NO change to loop logic or outcomes [U14][U15][U16][U17][U18] (FR-001, T1–T4, SC-005).

---

## Phase 4: User Story 2 (P1) — Ziki publishes state authoritatively

**Goal**: Ziki pushes its state to Herdr the moment it changes.
**Independent Test**: transition idle→working→blocked→idle and confirm Herdr records each transition with the goal session id.

- [x] T013 [US2] Write FAILING tests for `HerdrHttpClient` serializing `PaneReportParams` to the exact contract §2 JSON body and POSTing to the configured endpoint over a `FakeTransport` [U11][U13] (FR-002, contract §2).
- [x] T014 [US2] Make T013 green by completing T005 (FR-002) [U11].
- [x] T015 [US2] Write FAILING tests for monotonic `seq` across rapid publishes and terminal `idle` on completion/abort, via composed GoalExecutor + StatePublisher + fakes [U4][U15][U16] (FR-006, SC-006).
- [x] T016 [US2] Make T015 green via T004/T012 (FR-006, SC-006) [U4][U15][U16].
- [x] T022 [US2] Write FAILING test for `HerdrHttpClient` defaulting `HERDR_API_URL` to `http://localhost:7878` when the env var is unset (boundary: env set vs unset) [U12] in `src/agent/herdr.zig`.
- [x] T023 [US2] Make T022 green via T005 (FR-002) [U12].

---

## Phase 5: User Story 3 (P2) — detectable without the push path

**Goal**: Herdr still classifies the pane from screen markers + OSC when the push API is unavailable.
**Independent Test**: disable push, run Ziki emitting markers + OSC, confirm `ziki.toml` manifest classifies working/blocked/idle.

- [x] T017 [US3] Write FAILING tests asserting the screen marker and OSC title emitted by `publish` exactly match contract §3/§4 tokens (`[ziki-state: <state>]`, `\x1b]2;ziki:<state>\x07`) for every state [U5][U6][U7] (FR-003, FR-004).
- [x] T018 [US3] Make T017 green via T004 (FR-003, FR-004, FR-007) [U5][U6][U7].
- [x] T024 [US1] Write FAILING test for push-authoritative consistency: for every state, the pushed `state` equals the on-screen marker's state [U10] in `src/agent/state.zig`.
- [x] T025 [US1] Make T024 green via T004 [U10].

---

## Phase 6: User Story 4 (P3) — human sees Ziki's live status (cross-repo)

**Goal**: Herdr sidebar shows working/blocked/idle badges per Ziki pane.
**Independent Test**: run a goal that blocks on input; confirm the Herdr sidebar shows the blocked indicator.

- [x] T019 [US4] Document in `quickstart.md` that US4 is satisfied entirely by FR-001…FR-008 + the Herdr-side `Agent::Ziki` variant and `ziki.toml` manifest (cross-repo partner); no Ziki code change required.

---

## Phase 7: Outer-loop acceptance gates (must be green before story complete)

- [x] T026 [US1] Write integration test (composed GoalExecutor + StatePublisher with `FakeHerdrReporter` + capturing sink) asserting mid-goal push=`working` with full `PaneReportParams` + working marker/OSC [A1].
- [x] T027 [US1] Write integration test asserting blocked push=`blocked` + `message` + blocked marker/OSC [A2].
- [x] T028 [US1] Write integration test asserting terminal `idle` push on goal end (no stale `working`) [A3].
- [x] T029 [US3] Write integration test asserting degraded screen/OSC emission without the push path, no crash [A4].
- [x] T030 [US2] Write integration test asserting strictly increasing `seq` across rapid transitions (no stale report wins) [A5].

---

## Phase 8: Polish & Cross-Cutting

- [x] T020 [P] Update README / docs with `HERDR_PANE_ID` and `HERDR_API_URL` env vars and the state-publication behavior (FR-008).
- [x] T021 Run `zig build test` and confirm the full suite is green; report coverage from `kcov` (optional) (SC-005).

---

## Dependencies

- T001 (register modules) → enables all test tasks.
- T002–T006 (foundational) → block US1/US2/US3 implementation (T010, T014, T016, T018, T023, T025).
- T007–T009 (US1 tests) → T010 (impl) must follow.
- T011–T012 (wiring) depend on T002–T006 and must not change executor logic (SC-005).
- T013 (US2 test) → T014 (impl); T022 (US2 test) → T023 (impl).
- T015 (US2 seq test) depends on T004/T012; T024 (US1 consistency) → T025.
- T017 (US3 test) → T018 (impl confirm).
- T026–T030 (outer acceptance) depend on the inner behaviors they compose (A1←U1/U3/U5/U6, A2←U2/U3/U7, A3←U15/U16, A4←U8/U9, A5←U4).
- T019 (US4 doc) is independent of all Ziki code.
- T020/T021 are final.

## Parallel Execution Examples

- T002, T003, T005, T006 can run in parallel (different files, no cross-deps).
- T007, T008, T009 (US1 tests) can run in parallel once T001 lands.
- T013 (US2 test) and T017 (US3 test) and T022/T024 can run in parallel.

## Implementation Strategy (MVP first)

- **MVP**: US1 + US2 (P1) — the push path + state machine + discovery. This alone makes Forklift coordination work against the Herdr API.
- **Increment 2**: US3 (P2) — screen/OSC fallback (cheap, reuses `publish`).
- **Increment 3**: US4 (P3) — Herdr-side UI (no Ziki change).

## Acceptance Criteria Coverage (from spec.md)

| AC | Story | Covered by |
|---|---|---|
| US1-1 (working mid-goal) | US1 | A1, U14, U1, U3, U5, U6 |
| US1-2 (blocked on input) | US1 | A2, U17, U2, U3, U7 |
| US1-3 (idle when ended) | US1 | A3, U15, U16 |
| US1-4 (unknown on death) | US1 | Herdr detection window (cross-repo, Out of scope) |
| US2-1 (working push) | US2 | A1, U3, U11, U12 |
| US2-2 (blocked push w/ message) | US2 | A2, U3, U17 |
| US2-3 (terminal idle push) | US2 | A3, U15, U16 |
| US3-1 (working marker) | US3 | A4, U5, U8 |
| US3-2 (blocked marker) | US3 | A4, U7, U8 |
| US3-3 (OSC title) | US3 | A4, U6, U8 |
| US4-1 (blocked badge) | US4 | T019 (cross-repo) |
| US4-2 (working badge) | US4 | T019 (cross-repo) |
