# Feature Specification: [Lane A] Goal loop hardening: resume, budgets, compaction, abort

**Feature Branch**: `013-goal-loop`

**Created**: 2026-09-16

**Status**: Draft

**Input**: Issue #16 — `runGoal()` always creates a fresh goal; no CLI path to resume a persisted goal from `FsGoalRepository`. Messages grow unbounded in a single arena across turns. The time budget is accepted/declared but never checked. `/stop` is only observed between turns; it must interrupt during provider I/O and long-running Bash tool calls. (Audit: spec 005 strict 10%, spec 006 strict 10% — code exists but the loop's hard edges are missing.)

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Resume an interrupted goal from the persisted store (Priority: P1)

A goal run is interrupted (process killed, terminal closed, crash). The goal and its conversation turns are already persisted by the executor after every turn. The user re-launches ziki and continues the goal from where it stopped — without re-stating the objective and without losing the work of prior turns.

**Why this priority**: Spec 005's core promise ("persisted state survives a process restart and can be reloaded and resumed without re-definition", FR-008/SC-004) is unfulfilled today: `runGoal()` always creates a fresh goal and no CLI path loads the store.

**Independent Test**: Seed a store with a persisted active goal plus saved turns, run `ziki resume [goal-id]`, and observe the next provider request contains the saved conversation (not just system + goal) and the loop continues to a terminal state using the persisted usage counters.

**Acceptance Scenarios**:

1. **Given** a persisted goal with status `active` and a saved conversation history, **When** the user runs `ziki resume [goal-id]` (or `/resume [goal-id]` in the REPL), **Then** the executor continues that goal: the first provider request contains the saved turns, and `used.turns/tokens` carry over rather than resetting.
2. **Given** no goal in the store, **When** the user runs `ziki resume`, **Then** ziki reports there is no goal to resume and starts nothing.
3. **Given** a goal id argument that does not match the stored goal, **When** the user runs `ziki resume nope-1`, **Then** ziki reports no such goal and starts nothing.
4. **Given** a goal already in a terminal state (completed/blocked/aborted), **When** the user runs `ziki resume [goal-id]`, **Then** ziki refuses with the current status and starts nothing.
5. **Given** a fresh `/goal` start, **When** the run begins, **Then** any stale conversation history from a previous goal in the same session is cleared so a later resume never replays a foreign conversation.

### User Story 2 - Token budget with context compaction (Priority: P1)

The conversation grows every turn inside a single arena. The executor sums usage across turns (provider-reported token usage when available, estimated from message sizes otherwise) and, when the token budget is exceeded, first compacts (trims) the older middle of the conversation and continues; if the budget is still exceeded after compaction (or there is nothing left to trim), it stops the goal gracefully in a defined stopped status instead of overflowing or looping.

**Why this priority**: Spec 006 FR-006 requires "when any budget (turns, tokens, time) is exceeded, the loop MUST stop the goal" and the plan's assumption requires compaction before overflow; today nothing is measured and nothing is trimmed.

**Independent Test**: Drive the loop with scripted providers and a small token budget; assert (a) a budget exceedance with trimmable history compacts and the run continues, (b) a budget exceedance with nothing left to trim ends the goal gracefully with a "token budget exceeded" stop reason and a persisted status.

**Acceptance Scenarios**:

1. **Given** a goal whose accumulated usage crosses `budgets.max_tokens` while older middle messages exist, **When** the turn completes, **Then** the executor compacts the conversation (system prompt + original goal message + recent turns retained), reports the compaction in the job report, and the next provider request is smaller.
2. **Given** a goal whose accumulated usage crosses `budgets.max_tokens` again after compaction (or with nothing trimmable), **When** the turn completes, **Then** the goal transitions to `aborted` with progress "aborted: token budget exceeded", the status is persisted, and no further provider/tool calls happen.
3. **Given** a provider response that reports token usage, **When** a turn completes, **Then** the reported usage is added to `goal.used.tokens`; **Given** a provider that reports nothing, **Then** usage is estimated from the conversation size so the budget is still enforced.
4. **Given** a resumed goal, **When** the loop runs, **Then** token usage accounting continues from the persisted `used.tokens` rather than from zero.

### User Story 3 - Time budget enforcement (Priority: P2)

A time budget is declared (`Budgets.max_seconds`, persisted with the goal) but never checked. The turn loop enforces it: elapsed time is accumulated into `goal.used.seconds` (carried across resumes via persistence) and an exceedance stops the goal gracefully.

**Why this priority**: Same FR-006 mandate as tokens; slightly lower priority because runaway time is bounded today by the turn budget and the Bash per-command timeout.

**Independent Test**: Set a goal's time budget so it is already exhausted (max_seconds = 0 with zero elapsed); run one turn; assert the goal ends gracefully in a stopped status with a "time budget exceeded" stop reason before any provider call.

**Acceptance Scenarios**:

1. **Given** a goal whose `used.seconds` (carried + this run's elapsed) reaches `budgets.max_seconds`, **When** the turn loop checks at the top of a turn, **Then** the goal transitions to `aborted` with progress "aborted: time budget exceeded" and the status is persisted.
2. **Given** `/goal --timeout <s>` (or `--no-timeout`), **When** the goal starts, **Then** the goal's `budgets.max_seconds` reflects it, so the wall-clock budget the user expressed on the CLI is the one enforced.

### User Story 4 - Mid-turn abort (Priority: P2)

`/stop` writes a stop file that is only observed between turns. The abort must be observed during a turn: before each tool dispatch, during long-running Bash tool commands (killing the child), and during provider I/O (an in-flight completion is abandoned and its result discarded — the abort wins over a concurrent provider response).

**Why this priority**: Spec 006 FR-007/SC-002 require the abort to win and no further work after the signal; the current between-turns-only check can leave the loop unresponsive for minutes (long Bash commands, long provider calls).

**Independent Test**: With a stop signal raised during a turn: (a) a Bash tool command is terminated promptly and the goal aborts; (b) a provider call that finishes after the signal has its response discarded, and no tool calls from that response execute.

**Acceptance Scenarios**:

1. **Given** a long-running Bash command and a stop signal raised while it runs, **When** the Bash tool's poll loop observes the stop, **Then** the child is killed (SIGTERM), the tool returns an aborted result, and the goal transitions to `aborted` with the status persisted.
2. **Given** a stop signal raised while the executor awaits a provider completion, **When** the provider call returns (however late), **Then** the response is discarded: no messages are appended, no tool calls execute, the goal transitions to `aborted` and is persisted.
3. **Given** a stop signal observed, **When** the current turn unwinds, **Then** no further provider or tool calls occur (spec 006 "abort must win").
4. **Given** the user presses Ctrl-C (SIGINT) during a goal run, **When** the signal handler fires, **Then** the stop file is written so the loop aborts gracefully and saves state (instead of dying mid-turn with no save).

### Edge Cases

- Compaction must always retain the system prompt and the original goal message; a tool result is never left dangling without its assistant tool_calls message.
- Budget checks must run on resumed goals too (persisted `used` counters are the starting point).
- Abort during a retry sleep or between retry attempts stops the retry loop immediately (no further provider attempts).
- A missing/corrupt history file is treated as an empty history (fresh conversation) — resume still works with goal state alone.
- `--no-timeout` disables the goal wall-clock budget (max_seconds = maxInt) matching the Bash tool semantics.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The CLI MUST provide `ziki resume [goal-id]` (and REPL `/resume [goal-id]`) that loads the persisted goal from `FsGoalRepository` and continues it, loading any persisted conversation turns.
- **FR-002**: Resuming MUST refuse gracefully when there is no goal, when the id does not match, or when the goal is already terminal; each case is a clear message, never a crash.
- **FR-003**: The executor MUST persist the conversation transcript after each turn so a later resume replays it; a fresh `/goal` MUST clear any stale transcript.
- **FR-004**: The executor MUST accumulate token usage across turns (provider-reported usage when present, estimated otherwise) and compare it against `budgets.max_tokens`.
- **FR-005**: When the token budget is exceeded and the conversation has trimmable middle history, the executor MUST compact (retain system prompt, original goal message, and the most recent messages) and continue the run; the compaction MUST be reported.
- **FR-006**: When the token budget is exceeded and compaction cannot relieve it (already compacted or nothing to trim), the executor MUST stop the goal gracefully (`aborted`, "aborted: token budget exceeded"), persist the status, and perform no further provider/tool calls.
- **FR-007**: The executor MUST accumulate elapsed wall time into `used.seconds` (carried over on resume) and enforce `budgets.max_seconds` at the top of each turn; exceedance stops the goal gracefully ("aborted: time budget exceeded") with a persisted status.
- **FR-008**: The executor MUST observe the stop signal within a turn: before each tool dispatch, inside long-running Bash commands (terminate the child), and during provider I/O (discard an in-flight result); after observation, no further provider or tool calls occur.
- **FR-009**: SIGINT/SIGTERM during a goal run MUST write the stop file so the loop aborts gracefully and saves state.
- **FR-010**: `--timeout`/`--no-timeout` on `/goal` MUST set the goal's time budget; `--max-tokens` and `--max-turns` MUST override the token/turn budgets.

### Key Entities

- **Goal** (`src/goal/goal.zig`): unchanged shape; `used.tokens`/`used.seconds` become live counters maintained by the loop; `budgets.max_seconds` becomes enforced.
- **Conversation history**: the persisted `ChatMessage` transcript of the active goal, stored per session next to the goal file (`<dir>/history.<session>.json`), owned by `FsGoalRepository`.
- **Stop probe**: an injectable "should stop?" check (file-based by default; testable atomic/file fakes), consumed by the executor turn loop, the Bash tool poll loop, and the provider I/O wait loop.
- **Turn usage**: per-turn token accounting (reported or estimated) summed into `goal.used.tokens`.

### Success Criteria *(measurable)*

- **SC-001**: `ziki resume [goal-id]` loads turns from the store: the first provider request after resume contains the persisted prior turns in 100% of test cases (resume round-trip).
- **SC-002**: Budget exhaustion stops gracefully: token and time exceedance each end the goal in a defined stopped status with the status persisted, zero further provider/tool calls, in 100% of test cases.
- **SC-003**: Context compaction triggers when the token budget is exceeded and leaves a conversation that still contains the system prompt and the original goal message in 100% of test cases.
- **SC-004**: Mid-turn abort: a stop raised during a Bash command or provider I/O interrupts within one poll interval (~200 ms) in test cases, with no tool executions after the signal.
- **SC-005**: `zig build test` green on zig 0.15.2 (CI gate) with all pre-existing tests still passing.

## Out of Scope

- Tool error propagation changes → Lane C.
- Push gate / already-applied handling → Lane D.
- Tool registry changes and provider error-propagation semantics (only additive usage reporting is touched in `provider/`).
- Socket-level cancellation of HTTP reads (abandon-and-discard semantics only; transport timeouts remain the transport's concern).
