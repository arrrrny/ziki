# Plan: Goal State & Persistence

**Feature**: `005-goal-state-persistence`
**Status**: Implemented and verified; merged to `MASTER` via PR #1. This plan
documents the design and verification evidence for sign-off.

## Goal

Represent a goal as a single entity with a fixed four-state lifecycle
(`active` / `completed` / `blocked` / `aborted`), model its transitions as an
explicit, testable state machine, and persist it to a durable store so it
survives a restart and resumes without re-definition. Independent of any live
provider or agent loop.

## Architecture & Key Decisions

- **Goal entity** (`goal.zig`): holds `objective`, optional `completion_criterion`,
  `status`, `progress`, `budgets` (turns/tokens/time), `created`/`last_updated`
  timestamps, owning `session_id`, and a final `summary` when stopped.
  `Goal.init` sets `status = active` and stamps both timestamps (FR-001, FR-002,
  FR-003).
- **State machine**: `Status` (enum) with `jsonString`/`fromJson` helpers;
  transitions are explicit methods that validate the move and reject illegal ones
  (e.g. `aborted → completed`), leaving state unchanged and returning a clear
  reason (FR-004, FR-005).
- **Store abstraction** (`repository.zig` + `fs.zig`): `GoalRepository` is a
  vtable behind an `Fs` interface; `FsGoalRepository` persists a single goal per
  session under `.ziki/`. Reload restores objective/status/progress/budgets/
  timestamps exactly, and the reloaded goal can continue transitioning
  (FR-006, FR-007, FR-008).
- **Isolation**: the file-backed store gives per-session isolation so separate
  windows observe consistent state without corruption (FR-009). Corrupt/unreadable
  entries surface a clear error rather than a wrong goal (FR-010).

## Files

| File | Responsibility |
|------|----------------|
| `src/goal/goal.zig` | `Goal` entity + `Status` state machine |
| `src/goal/repository.zig` | `GoalRepository` interface + `FsGoalRepository` |
| `src/fs/fs.zig` | `Fs` interface (used as the durable store medium) |

## Verification Evidence

- `zig build test` → 23/23 pass on a clean compile. Goal coverage:
  - `Status json round-trip` (goal.zig) — status serialization.
  - `Goal.init builds a goal` (goal.zig) — entity creation + initial status.
  - `FsGoalRepository round-trip and isolation` (repository.zig) — persist,
    reload, exact match, resume, and per-session isolation.
- These cover FR-001..FR-010 and SC-001..SC-005 with no provider/agent
  dependency.

## Notes

Behavior is fully specified in `spec.md`. The agent loop that drives transitions
during a live run is spec 006; resume here means the state survives and reloads,
not auto-restarting the loop.
