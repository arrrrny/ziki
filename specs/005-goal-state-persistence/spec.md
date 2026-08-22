# Feature Specification: Goal State & Persistence

**Feature Branch**: `[005-goal-state-persistence]`

**Created**: 2026-08-22

**Status**: Draft

**Input**: User description: "Goal state model and persistence for the Zig Goal CLI. A goal is the unit of autonomous work and MUST be represented as a clear entity with: an objective (natural-language text), an optional completion criterion, a status (active / completed / blocked / aborted), a progress indicator, budgets (turns, tokens, time), and timestamps (created, last updated) tied to an owning session. The goal state MUST be persisted to a durable store so it survives a process restart and can be reloaded and resumed without re-definition. The state transitions (start, progress, complete, block, abort) MUST be explicit and testable as a state machine, not implicit in the agent loop. Must be independently testable: in tests a goal is created, mutated through transitions, serialized, reloaded from the store, and asserted to match — including that an interrupted active goal resumes from its saved progress rather than restarting. Definition of done: the Goal entity, its status state machine, and its persistence/reload/resume are each covered by tests, with no dependency on a live provider or agent. This is required by the autonomous goal execution feature and by the multi-window memory feature."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Define and track a goal (Priority: P1)

A user (or the agent loop) creates a goal with an objective and an optional completion criterion. The goal is represented as a single entity holding its status, progress, budgets, and timestamps, and can be inspected at any time.

**Why this priority**: The goal entity is the backbone every other feature reads and writes; without a clear model nothing else can track work.

**Independent Test**: Create a goal with a given objective and criterion, assert its initial status is active and its timestamps are set, then assert a progress update changes the progress indicator and bumps the last-updated timestamp.

**Acceptance Scenarios**:

1. **Given** an objective and a completion criterion, **When** a goal is created, **Then** its status is `active`, progress is empty/zero, and created/updated timestamps are set.
2. **Given** an active goal, **When** progress is recorded, **Then** the progress indicator reflects it and `last_updated` advances.

---

### User Story 2 - Transition a goal through its lifecycle (Priority: P1)

A goal moves through explicit states: it starts active, can be marked progressing, completes, becomes blocked, or is aborted. Every transition is validated so illegal moves (e.g. completing an already-aborted goal) are rejected.

**Why this priority**: The state machine is what keeps the agent loop and the user interface consistent and prevents contradictory states.

**Independent Test**: Drive a goal through allowed transitions (active -> completed, active -> blocked, active -> aborted, blocked -> active on retry) and assert each results in the expected status; attempt an illegal transition and assert it is rejected.

**Acceptance Scenarios**:

1. **Given** an active goal, **When** it meets its criterion, **Then** it transitions to `completed` and records a final summary.
2. **Given** an active goal that cannot proceed, **When** it is blocked, **Then** its status becomes `blocked` with a reason.
3. **Given** an aborted goal, **When** a transition to `completed` is attempted, **Then** the transition is rejected.

---

### User Story 3 - Persist and resume a goal across restart (Priority: P1)

An active (or any) goal is written to a durable store. If the process stops and later reloads, the same goal is restored with its status and accumulated progress, and can continue without re-definition.

**Why this priority**: Power users keep many windows open for long periods; durability is what makes a goal dependable and is required for the multi-window scenario.

**Independent Test**: Create and partially progress a goal, persist it, simulate a restart by reloading from the store in a fresh instance, and assert the reloaded goal matches (same objective, status, progress) and can continue transitioning.

**Acceptance Scenarios**:

1. **Given** an active goal with partial progress that has been persisted, **When** it is reloaded after a restart, **Then** it is restored with the same objective, status, and progress, and is not re-prompted as new.
2. **Given** a completed goal that has been persisted, **When** reloaded, **Then** it is shown as `completed` with its summary intact.
3. **Given** a goal written by one window, **When** a second window in the same session reloads it, **Then** the second window sees the same state (no loss or duplication).

---

### Edge Cases

- Reload of a corrupt or partially written store entry: must be reported as an error and not silently produce a wrong goal.
- Two windows writing the same goal concurrently: writes must not corrupt each other (isolation/atomicity rule defined).
- Transition to a status from an invalid current status: rejected with a clear reason, state unchanged.
- Budget exhausted (turns/tokens/time): the goal must transition to a defined stopped state (blocked or aborted) rather than looping.
- Completion criterion omitted: goal is still creatable; completion is then judged by an alternative defined rule (e.g. agent-declared done) rather than failing to start.
- Very long objective text: stored and reloaded without truncation.
- Clock skew / non-monotonic time: timestamps must remain valid (monotonic or clearly defined) so ordering is sound.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST represent a goal as a single entity with objective, optional completion criterion, status, progress, budgets, and created/updated timestamps tied to an owning session.
- **FR-002**: System MUST support exactly the statuses `active`, `completed`, `blocked`, and `aborted`, and MUST expose the current status for inspection.
- **FR-003**: System MUST support recording progress against a goal and updating the `last_updated` timestamp on change.
- **FR-004**: System MUST model goal lifecycle transitions (start, progress, complete, block, abort) as an explicit, testable state machine.
- **FR-005**: System MUST reject illegal status transitions and leave the goal's state unchanged when a transition is invalid, reporting a clear reason.
- **FR-006**: System MUST persist goal state to a durable store so it survives a process restart.
- **FR-007**: System MUST reload a persisted goal and restore its objective, status, progress, budgets, and timestamps exactly.
- **FR-008**: System MUST allow a reloaded goal to continue transitioning (resume) without re-definition.
- **FR-009**: System MUST handle concurrent writes to the same goal from different windows without corrupting state (isolation/atomicity rule).
- **FR-010**: System MUST report a clear error on reload of a corrupt or unreadable store entry rather than producing an incorrect goal.

### Key Entities *(include if feature involves data)*

- **Goal**: The unit of autonomous work. Attributes: id, objective, completion criterion (optional), status, progress indicator, budgets (turns, tokens, time), created timestamp, last-updated timestamp, owning session id, final summary (when stopped).
- **Goal Status**: A discrete state in the lifecycle. Values: active / completed / blocked / aborted.
- **Transition**: A validated move from one status to another with a reason; illegal moves are refused.
- **Goal Store**: The durable backing that saves and loads goals; abstracts the storage medium so tests can use an in-memory or file-backed store.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A goal can be created and its status, progress, and timestamps asserted; 100% of create/progress cases pass automated tests.
- **SC-002**: All legal transitions (active→completed, active→blocked, active→aborted, blocked→active, etc.) and 100% of illegal transitions are validated correctly by automated tests (illegal moves rejected, state unchanged).
- **SC-003**: A goal persisted by one instance is reloaded by a fresh instance with objective, status, and progress exactly matched in 100% of test cases, and can resume transitioning.
- **SC-004**: Concurrent/separate-window writes to the same goal do not corrupt state in 100% of test cases (defined isolation behavior).
- **SC-005**: Corrupt or missing store entries are reported as errors (not silent wrong goals) in 100% of relevant test cases; budget exhaustion reliably moves the goal to a defined stopped state.

## Assumptions

- **Durable store abstraction**: The store is behind an interface so tests can use an in-memory or file-backed implementation; the exact medium is an implementation detail, not specified here.
- **Status set is fixed**: The four statuses (active/completed/blocked/aborted) are mandated by the master spec (001) and are not extensible in this feature.
- **Budgets**: Turns, tokens, and time are tracked as numeric limits; when exceeded the goal moves to a defined stopped state. Exact default values are configured elsewhere.
- **Resume semantics**: "Resume" means continue the same goal from saved progress; it does not mean auto-restarting the agent loop (that is the execution feature's job). This feature only guarantees the state survives and reloads.
- **No provider/agent dependency**: This feature is testable purely as entity + state machine + store, independent of a live model backend or agent loop.
- **Concurrency rule**: Multi-window isolation is required (per master spec edge case); the precise locking/atomicity mechanism is an implementation detail, but the no-corruption guarantee is fixed.
- **Language**: Implementation is in Zig per the overarching project constraint; this spec describes behavior, not code.

## Note on Scope (relationship to master spec 001)

The master feature requires goals to persist and resume (FR-006, SC-004) and to be reported with status (FR-003). This spec delivers the Goal entity, its state machine, and persistence/resume as a standalone, testable unit. The agent loop that drives transitions during a live run is a separate later feature (autonomous goal execution).
