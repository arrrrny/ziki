---
feature: 013-goal-loop-hardening
loop: outside-in
profile: .specify/memory/tdd-profile.md
updated: 2026-09-16
---

# Test List — 013-goal-loop-hardening

Trace key: SC → spec success criterion; FR → spec functional requirement.

| ID | Behavior (input/precondition → observable result) | Trace | State |
|----|----------------------------------------------------|-------|-------|
| B1 | History saved by `FsGoalRepository` round-trips: `save_history(goal_id, msgs)` then `load_history(goal_id)` returns the same roles/contents/tool_calls | SC-001, FR-003 | done |
| B2 | `load_history` with a stored goal_id that differs from the requested one returns null (no cross-goal replay) | FR-002 | done |
| B3 | `load_history` on a missing or corrupt history file returns null (resume still possible from goal state) | FR-002 | done |
| B4 | `clear_history` removes the stored transcript (later `load_history` → null) | FR-003 | done |
| B5 | Executor persists the transcript after each turn: after a scripted run, `load_history(goal.id)` returns the conversation including system, goal user message, assistant and tool messages | SC-001, FR-003 | done |
| B6 | Executor seeded with a saved history sends it verbatim: the recorded provider request contains the seeded prior turns before the new turn | SC-001, FR-001 | done |
| B7 | Token budget exceeded with trimmable history → conversation compacted: retains system prompt + original goal message + recent window + compaction notice; run continues and completes | SC-003, FR-005 | done |
| B8 | Compaction trims the middle only: dropped-token accounting reduces `used.tokens` by the removed estimate and the message count shrinks | SC-003, FR-005 | done |
| B9 | Token budget exceeded with nothing trimmable (single-turn conversation) → goal `aborted`, progress "aborted: token budget exceeded", status persisted, no further provider calls | SC-002, FR-006 | done |
| B10 | Provider-reported usage is summed into `used.tokens`; a provider without usage falls back to the bytes/4 estimate (both paths observable via `goal.used.tokens` / persistence) | FR-004 | done |
| B11 | Time budget already exhausted (`max_seconds=0`) → goal `aborted` with "aborted: time budget exceeded" before any provider call, status persisted | SC-002, FR-007 | done |
| B12 | Stop probe observed before each tool dispatch: a tool whose execution context signals stop (via probe flag set by a prior tool) is never dispatched after the signal (abort wins) | SC-004, FR-008 | done |
| B13 | Provider response arriving after stop was requested is discarded: no message appended, its tool calls never execute, goal `aborted` + persisted | SC-004, FR-008 | done |
| B14 | Bash tool with stop probe set mid-command: child killed, result `ok=false` "aborted by user", `aborted=true` set | SC-004, FR-008 | done |
| B15 | Executor maps an aborted Bash tool result to goal `aborted` + persisted status, no further provider calls | SC-004, FR-008 | done |
| B16 | Retry loop is abort-aware: stop requested between attempts ends the retry loop immediately (no further attempts) | FR-008 | done |
| B17 | Resume CLI guards: no stored goal → "no goal to resume"; mismatched id → "no such goal"; terminal goal → refuses with current status (core function messages observable) | FR-002 | done |
| B18 | Resume end-to-end round-trip through the store: run a scripted goal to an interrupted state, resume it with a fresh executor seeded from the repository, loop completes with carried-over usage counters | SC-001, FR-001 | done |
| B19 | ChatResponse.usage defaults to null; OpenAI parseResponse maps `usage.prompt_tokens`/`completion_tokens` when present and tolerates omission | FR-004 | done |
| B20 | Regression invariant: all pre-existing tests stay green; budget/abort changes do not alter no-budget-no-stop behavior of existing executor tests | SC-005 | done |

## Acceptance tests (outer loop)

| ID | Acceptance criterion | State |
|----|----------------------|-------|
| A1 | `ziki resume [goal-id]` loads turns from store (B5+B6+B18 through the repository interface) | done |
| A2 | Budget exhaustion → graceful stop, token + time (B9+B11) | done |
| A3 | Mid-turn abort: `/stop` interrupts provider I/O and Bash tool (B13+B14+B15) | done |
| A4 | Context compaction when token budget exceeded (B7+B8) | done |
| A5 | `zig build test` green on zig 0.15.2 (B20) | done |
