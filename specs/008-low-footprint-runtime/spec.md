# Feature Specification: Low-Footprint Multi-Window Runtime

**Feature Branch**: `[008-low-footprint-runtime]`

**Created**: 2026-08-22

**Status**: Draft

**Input**: User description: "Low-footprint multi-window runtime and memory budgeting for the Zig Goal CLI. The entire reason for the Zig rewrite is memory: the TypeScript version fills over 10 GB with 20 windows open, and the user expects the rewrite to cut that to at most one-eighth (around 1.25 GB or less) at the same scale. This feature defines the runtime properties and measurement that guarantee bounded, small per-window memory: each agent window (an instance using the CLI shell, goal state, provider, tools, and execution loop from the earlier features) MUST have a bounded baseline memory cost, and running many windows concurrently MUST stay within the total budget. It MUST be independently verifiable: a memory harness launches N windows (including N=20 with active goals) and asserts total resident memory at steady state does not exceed the budget, and that a single idle window has a small, bounded footprint. Definition of done: a measurement harness proves 20 concurrent windows stay at or below one-eighth of the current TypeScript baseline, satisfying master spec SC-002. This is the property that justifies the rewrite and is tested as a system-level budget, not per-feature."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Run 20 windows within the memory budget (Priority: P1)

The user opens 20 agent windows simultaneously (one per project/task), each holding an active goal, and the combined resident memory stays at or below one-eighth of the current TypeScript baseline (~10 GB), i.e. roughly 1.25 GB or less at steady state.

**Why this priority**: This is the single reason the rewrite exists; if the budget is not met, the project has failed its core purpose.

**Independent Test**: Launch 20 agent windows each with an active goal via a memory harness, let them reach steady state, and measure total resident memory; assert it is ≤ one-eighth of the baseline. No manual observation required.

**Acceptance Scenarios**:

1. **Given** 20 windows each with an active goal at steady state, **When** total resident memory is measured, **Then** it does not exceed one-eighth of the current TypeScript baseline.
2. **Given** the baseline measurement is unavailable, **When** measured, **Then** the total is at or below the absolute budget (roughly 1.25 GB) used as the proxy.

---

### User Story 2 - A single idle window is tiny (Priority: P1)

One idle agent window (no active goal work) has a small, bounded memory footprint, proving there is no per-window memory bloat beyond a baseline cost.

**Why this priority**: If even one window is heavy when idle, 20 of them can never meet the budget; idle cost is the floor the budget is built on.

**Independent Test**: Launch one idle window, measure its resident memory after startup settles, and assert it is a small, bounded value within the per-window allowance implied by the total budget.

**Acceptance Scenarios**:

1. **Given** a single idle window, **When** memory is measured after startup, **Then** its footprint is a small, bounded baseline cost (no unbounded growth).
2. **Given** the window stays idle for an extended period, **When** re-measured, **Then** memory has not grown beyond the bounded baseline.

---

### User Story 3 - Memory is measured by a repeatable harness (Priority: P2)

A measurement harness can launch N windows (including N=20 with active goals), let them settle, and report total and per-window resident memory, so the budget is verified automatically and repeatedly, not by hand.

**Why this priority**: Without a repeatable measurement, the budget claim cannot be defended or regression-tested; this makes SC-002 a real, enforced criterion.

**Independent Test**: Run the harness for several N values (e.g. 1, 5, 20) and assert it reports consistent, monotonic-bounded totals and flags the budget breach when exceeded.

**Acceptance Scenarios**:

1. **Given** the harness configured for N windows, **When** run, **Then** it launches N windows, waits for steady state, and reports total and per-window memory.
2. **Given** a configuration that would exceed the budget, **When** the harness runs, **Then** it clearly reports the budget breach rather than passing silently.

---

### Edge Cases

- Memory grows during an active goal then settles: the budget is judged at steady state, not at peak; the harness must wait for settlement before asserting.
- A window crashes or fails to start: the harness must report the failure clearly and not produce a misleading (lower) memory number.
- Baseline (TypeScript) measurement is unavailable on a given machine: an absolute proxy budget (roughly 1.25 GB at 20 windows) is the fallback assertion.
- A single window temporarily exceeds its share due to a large file/response in context: the design must bound this (e.g. context compaction, streaming) so the total still meets the budget at steady state.
- Leak over long idle time: an idle window must not accumulate memory; the harness may hold idle windows and re-measure to catch leaks.
- Non-uniform windows (some idle, some active): the total budget applies to the mixed population, not just uniform cases.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Each agent window MUST have a bounded baseline memory cost, with no unbounded per-window growth over time or across goals.
- **FR-002**: Running many concurrent windows MUST keep total resident memory within the defined budget (at most one-eighth of the current TypeScript baseline, used as the proxy budget).
- **FR-003**: A single idle window MUST have a small, bounded footprint that serves as the per-window floor of the budget.
- **FR-004**: The system MUST provide a memory measurement harness that launches N windows (including N=20 with active goals), waits for steady state, and reports total and per-window resident memory.
- **FR-005**: The harness MUST assert the budget and clearly report a breach when total memory exceeds it, rather than passing silently.
- **FR-006**: The budget MUST be judged at steady state, not at transient peak, and the harness MUST wait for settlement before asserting.
- **FR-007**: The design MUST bound memory during active work (e.g. via context handling/streaming) so the total still meets the budget at steady state even with large inputs.
- **FR-008**: The harness/reporting MUST handle window start failures clearly so a failed launch is not mistaken for a low memory reading.
- **FR-009**: When the baseline (TypeScript) measurement is unavailable, the system MUST fall back to the absolute proxy budget (roughly 1.25 GB at 20 windows) as the assertion.
- **FR-010**: Memory behavior MUST be regression-testable: the same harness run MUST be repeatable and MUST flag budget regressions automatically.

### Key Entities *(include if feature involves data)*

- **Agent Window**: One running instance combining the CLI shell, goal state, provider, tools, and execution loop. Attributes: working directory, active goal reference, steady-state memory cost.
- **Memory Budget**: The total resident-memory limit across windows (at most one-eighth of the current TypeScript baseline; proxy ~1.25 GB at 20 windows). Attributes: limit, basis (baseline or proxy), steady-state rule.
- **Memory Harness**: The measurement component that launches N windows, waits for steady state, and reports/asserts memory against the budget.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 20 concurrent windows each with an active goal stay at or below one-eighth of the current TypeScript baseline (proxy ~1.25 GB) in total resident memory at steady state, verified by the harness (master spec SC-002).
- **SC-002**: A single idle window has a small, bounded footprint that does not grow over an extended idle period, verified by the harness.
- **SC-003**: The memory harness launches N windows (including 20 with active goals), reaches steady state, and reports total and per-window memory automatically and repeatably.
- **SC-004**: Any configuration exceeding the budget is clearly reported as a breach by the harness in 100% of such cases; no silent pass.
- **SC-005**: Memory behavior is regression-protected: the same harness run flags a budget regression automatically, so the rewrite's core benefit cannot silently regress.

## Assumptions

- **Budget basis**: The budget is expressed relative to the current TypeScript baseline the user reports (~10 GB at 20 windows); the target is ≤ 1/8 of that. Where the baseline cannot be measured on a given machine, the absolute proxy (~1.25 GB at 20 windows) is the assertion fallback.
- **Steady state, not peak**: Budget is verified at steady state after settlement; transient peaks during active work are allowed as long as the steady-state total meets the budget.
- **Composition**: A "window" is the composition of earlier features (002 shell, 003 tools, 004/007 provider, 005 goal state, 006 execution loop); this feature constrains their combined memory, it does not re-implement them.
- **Bounded active memory**: Large context/responses are handled by bounding mechanisms (e.g. context compaction, streaming) so totals stay within budget; the exact mechanism is an implementation detail, but the bounded outcome is required.
- **Measurement method**: Resident memory is measured by the harness via the platform's standard process-memory reporting; the harness abstracts the measurement so it is repeatable.
- **Language**: Implementation is in Zig per the overarching project constraint; this spec describes the memory property and its verification, not code.
- **Cosmetics irrelevant**: As with the whole project, visual/theming concerns do not affect this feature.

## Note on Scope (relationship to master spec 001)

The master feature's memory success criterion (SC-002) is realized by this feature composed with 002–007. This spec defines the bounded-memory property and the automatic, repeatable measurement that enforces it. It is the property that justifies the Zig rewrite and is tested at the system level, not per feature.
