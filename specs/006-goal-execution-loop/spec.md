# Feature Specification: Goal Execution Loop

**Feature Branch**: `[006-goal-execution-loop]`

**Created**: 2026-08-22

**Status**: Draft

**Input**: User description: "Autonomous goal execution loop for the Zig Goal CLI. This is the core that makes the product's Definition of Done real: given a Goal (from the goal-state feature), a Provider (from the provider-interface feature), and Tools (from the tool-abstraction feature), the loop drives the goal to completion with no per-step human input. Each iteration it builds the conversation (system prompt + goal objective/criterion + message history + available tool descriptions), asks the provider for a completion, and if the completion contains tool calls it executes them via the Tool layer and feeds the results back; if the completion signals finished (or the goal's completion criterion is satisfied) it marks the goal completed with a summary; if the provider reports blocked or a budget (turns/tokens/time) is exceeded it stops in the corresponding status. The loop MUST depend only on the injected Goal, Provider, and Tool interfaces (Dependency Inversion per the constitution), so it is fully testable with a fake provider and fake tools driving a scripted scenario to completion. Definition of done: a scripted goal is driven end-to-end to a completed status without human input, using fakes for provider and tools, and stop conditions (blocked, aborted, budget exceeded) each move the goal to the correct status. This is the feature that satisfies the master spec's primary success criterion (SC-001)."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Drive a goal to completion autonomously (Priority: P1)

Given a goal, a provider, and tools, the loop runs without per-step human input: it asks the provider, executes any tool calls the provider returns, feeds the results back, and repeats until the goal's completion criterion is met or the provider signals finished. The goal is then marked completed with a summary.

**Why this priority**: This is the product's Definition of Done (master spec SC-001). Without it, nothing is actually accomplished.

**Independent Test**: Wire fakes for provider and tools that follow a scripted transcript (e.g. provider asks to read a file, then edit it, then finishes). Run the loop and assert the goal ends in `completed` with the expected tool calls performed and a summary recorded — no human input required.

**Acceptance Scenarios**:

1. **Given** a goal and a scripted provider that returns tool calls then a finish, **When** the loop runs, **Then** the goal reaches `completed` and each scripted tool was executed exactly once.
2. **Given** a goal whose completion criterion is satisfied by the provider's finish signal, **When** the loop runs, **Then** the goal is marked `completed` with a summary and the loop stops.
3. **Given** an in-progress goal, **When** the loop starts, **Then** it proceeds without prompting the user for each step.

---

### User Story 2 - Stop correctly on blocked or budget exhaustion (Priority: P1)

If the provider reports it is blocked, or any budget (turns, tokens, time) is exceeded, the loop stops the goal in the correct status instead of looping forever or crashing.

**Why this priority**: Unbounded loops and silent failures are the main risks of autonomy; safe stopping is mandatory.

**Independent Test**: Drive the loop with a provider that returns "blocked", and separately with a budget set so it is exceeded after one iteration; assert the goal ends in `blocked` in the first case and in the defined stopped status in the second, with no crash and no extra iterations.

**Acceptance Scenarios**:

1. **Given** a provider that reports blocked, **When** the loop runs, **Then** the goal transitions to `blocked` with a reason and the loop terminates.
2. **Given** a turn budget of 1 that is exhausted, **When** the loop runs one iteration, **Then** the goal moves to the defined stopped status and the loop terminates.
3. **Given** a provider that keeps returning tool calls with no finish, **When** the budget is reached, **Then** the loop stops rather than continuing indefinitely.

---

### User Story 3 - Abort on demand (Priority: P2)

The loop MUST honor an external abort signal (e.g. the `/stop` command from the CLI shell feature) and transition the goal to `aborted` cleanly, stopping any further provider calls.

**Why this priority**: Users must be able to halt a runaway or unwanted goal at any time; this connects the execution loop to the CLI dispatcher.

**Independent Test**: Start the loop against a provider that would otherwise run many iterations, raise the abort signal mid-run, and assert the goal becomes `aborted` and no further tool/provider calls occur.

**Acceptance Scenarios**:

1. **Given** a running loop, **When** an abort is signaled, **Then** the goal transitions to `aborted` and the loop ends.
2. **Given** an aborted goal, **When** inspected, **Then** its status is `aborted` and no further work was performed after the signal.

---

### Edge Cases

- Provider returns neither text nor a valid tool call: treated as an error and the goal moves to a defined stopped state rather than looping.
- Provider asks to call a tool not in the provided set: the loop must refuse that tool call and report it, not attempt to execute an unknown tool.
- Tool call fails: the failure result is fed back to the provider (so it can recover) rather than aborting the whole goal; repeated failure may eventually hit a budget/blocked stop.
- Completion criterion omitted: completion is judged by the provider's finish signal (per the goal-state feature's defined rule), not by failing to start.
- Context limit reached: the loop must compact/summarize prior history before the next provider call (behavior delegated to the provider/context handling), and continue.
- Concurrent abort and provider response: the abort must win; no work is performed after the signal.
- Persistence mid-run: progress is recorded to the goal state (feature 005) so a restart can resume rather than redo.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The execution loop MUST drive a goal to completion using only the injected Goal, Provider, and Tool interfaces (Dependency Inversion; no concrete implementations referenced).
- **FR-002**: Each iteration, the loop MUST build a conversation from a system prompt, the goal's objective and completion criterion, the message history, and the available tool descriptions, and request a completion from the provider.
- **FR-003**: When a completion contains tool calls, the loop MUST execute them via the Tool layer and feed the tool results back into the conversation for the next iteration.
- **FR-004**: When a completion signals finished (or the goal's completion criterion is satisfied), the loop MUST mark the goal `completed` with a summary and stop.
- **FR-005**: When the provider reports blocked, the loop MUST transition the goal to `blocked` with a reason and stop.
- **FR-006**: When any budget (turns, tokens, time) is exceeded, the loop MUST stop the goal in the defined stopped status and terminate.
- **FR-007**: The loop MUST honor an external abort signal and transition the goal to `aborted`, performing no further provider or tool calls.
- **FR-008**: The loop MUST refuse a tool call for a tool not present in the provided set and report it as an error rather than executing an unknown tool.
- **FR-009**: When a tool call fails, the loop MUST feed the failure result back to the provider rather than aborting the whole goal, allowing recovery.
- **FR-010**: The loop MUST record progress to the goal state (persistence feature) so work can be resumed after a restart, and MUST NOT loop indefinitely under any provider behavior.

### Key Entities *(include if feature involves data)*

- **Execution Loop**: The orchestrator that repeatedly queries the provider and executes tools until a stop condition. Depends only on the Goal, Provider, and Tool interfaces.
- **Iteration**: One cycle of the loop: build conversation -> request completion -> (execute tool calls) -> record progress -> check stop conditions.
- **Stop Condition**: A reason to end the loop: completed, blocked, aborted, or budget-exceeded.
- **Transcript / History**: The accumulating conversation (prompts, completions, tool calls, tool results) carried between iterations.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A scripted goal is driven end-to-end to `completed` status with no human input, using fake provider and tools, in 100% of scripted-completion test scenarios (master spec SC-001 satisfied).
- **SC-002**: Each stop condition (blocked, aborted, budget-exceeded) moves the goal to the correct status and terminates the loop in 100% of test cases, with no crash and no extra iterations.
- **SC-003**: The loop depends solely on the injected Goal/Provider/Tool interfaces; a test running the full loop against fakes with zero real provider or filesystem access passes, proving no concrete dependencies above the interfaces.
- **SC-004**: An unknown-tool call is refused and reported in 100% of test cases; a failed tool call is fed back (not aborting the goal) in 100% of test cases.
- **SC-005**: Under adversarial provider behavior (never finishes, always tool calls), the loop still terminates via budget/blocked stop in 100% of test cases — no infinite loop.

## Assumptions

- **Depends on earlier features**: This feature composes the Goal state (005), Provider interface (004), and Tool layer (003), plus the CLI dispatcher (002) for the abort signal. It adds the orchestration only.
- **Interface-first (constitution)**: Per the project constitution (Dependency Inversion, SOLID), the loop MUST reference only the Goal, Provider, and Tool interfaces; concretes are injected. Non-negotiable, and what makes it testable with fakes.
- **Stop statuses**: "blocked" and "aborted" are fixed statuses from the goal-state feature; budget-exceeded maps to a defined stopped status (blocked or aborted) per that feature's state machine.
- **Context compaction**: When history grows past a limit, the loop compacts/summarizes before the next provider call; the exact mechanism may involve the provider or a dedicated step, but the "continue without overflow" behavior is required.
- **Abort source**: The abort signal originates from the CLI dispatcher's `/stop` command (feature 002) and is delivered to the loop through a defined interface; the loop only needs to observe the signal.
- **Provider finish signal**: Completion is primarily signaled by the provider's finish response; when no explicit completion criterion is given, that signal alone suffices (per goal-state feature rule).
- **Language**: Implementation is in Zig per the overarching project constraint; this spec describes behavior, not code.

## Note on Scope (relationship to master spec 001)

The master feature's primary success criterion (SC-001: a goal is completed end-to-end like Kimi) is realized by this feature composed with 002/003/004/005. This spec delivers only the autonomous orchestration loop, not the underlying capabilities (those are their own features). With this feature in place, the MVP Definition of Done is achievable end-to-end.
