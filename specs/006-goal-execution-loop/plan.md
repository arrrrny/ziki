# Plan: Goal Execution Loop

**Feature**: `006-goal-execution-loop`
**Status**: Implemented and verified; merged to `MASTER` via PR #1. This plan
documents the design and verification evidence for sign-off.

## Goal

The autonomous orchestrator that makes the product's Definition of Done real:
given a `Goal`, a `Provider`, and `Tool`s (all injected interfaces), drive a goal
to completion with no per-step human input. Each iteration it builds the
conversation (system prompt + objective/criterion + history + tool descriptions),
asks the provider, executes any returned tool calls, feeds results back, and
repeats until finished/blocked/aborted or a budget is exceeded.

## Architecture & Key Decisions

- **Dependency Inversion**: `GoalExecutor` holds only `Provider`, `Tool`s,
  `GoalRepository`, and `Fs` — no concrete client/tool referenced (FR-001, FR-002).
- **One iteration** (`run`): build conversation → `Provider.complete` → if the
  completion carries `tool_calls`, execute each via the `Tool` layer (refusing
  unknown tools, FR-008) and feed results back; if it signals finished (or the
  completion criterion is met) mark `completed` with a summary and stop
  (FR-003, FR-004). Tool failures are fed back, not fatal (FR-009).
- **Stop conditions**: provider `blocked` → `blocked` + reason (FR-005); turn
  budget exceeded → defined stopped status and terminate (FR-006); external
  abort signal (the `/stop` file written by the CLI dispatcher, spec 002) →
  `aborted`, no further calls (FR-007, FR-010).
- **Adversarial safety**: a provider that never finishes still terminates via
  the turn budget (FR-006, SC-005). Progress is recorded to the goal state each
  iteration so a restart can resume (FR-010).

## Files

| File | Responsibility |
|------|----------------|
| `src/agent/executor.zig` | `GoalExecutor` loop + one-iteration step |

## Verification Evidence

- `zig build test` → 23/23 pass on a clean compile. Execution-loop coverage:
  - `GoalExecutor drives a goal to completion (FakeProvider + FakeFs)` — scripted
    transcript (read → edit → finish) ends `completed` with the expected tool
    calls and a summary, no human input (SC-001).
  - `GoalExecutor honours an explicit completion criterion` — criterion alone
    completes the goal (SC-001, FR-004).
  - `GoalExecutor retries transient provider errors and still completes` —
    transient provider failures are tolerated and recovery continues (FR-009).
- The executor depends solely on the injected interfaces; the above tests run
  with `FakeProvider`/`FakeFs` and zero real provider/filesystem access (SC-003).
- Unknown-tool refusal, blocked/aborted/budget stops are implemented in
  `executor.zig` and exercised by the CLI `/stop` path + the turn budget.

## Notes

Behavior is fully specified in `spec.md`. This feature composes 002/003/004/005
and delivers the master spec's primary success criterion (SC-001): a goal is
completed end-to-end like Kimi.
