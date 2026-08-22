# Contract: Goal State Schema (`goal/repository.zig`)

Goal state is persisted as JSON so it survives restart and resumes (FR-006).
This is the on-disk contract; the in-memory `Goal` struct maps 1:1.

## File location

`.ziki/goal.json` inside the session working directory, or a path from config.
Written after every turn. `GoalRepository.load` returns `null` if the file is
absent (fresh goal). A corrupt file yields a clear error, never silent success.

## JSON shape

```json
{
  "id": "goal-<uuid>",
  "objective": "add a function that ...",
  "criterion": "existing tests pass" | null,
  "status": "active | completed | blocked | aborted",
  "progress": "edited src/foo.zig, ran tests",
  "budgets": { "max_turns": 50, "max_tokens": 200000, "max_seconds": 1800 },
  "used": { "turns": 3, "tokens": 4200, "seconds": 12 },
  "created_at": 1766342400000,
  "updated_at": 1766342450000,
  "session_id": "win-<id>"
}
```

## Fields

| JSON key | Type | Rule |
|----------|------|------|
| id | string | unique |
| objective | string | non-empty |
| criterion | string or null | optional |
| status | string | one of the four enum values |
| progress | string | free text |
| budgets / used | object | integer caps and counters |
| created_at / updated_at | integer (epoch ms) | monotonic |
| session_id | string | owning window |

## Resume semantics (FR-006, spec edge cases)

- `status == "active"` on load -> executor continues the loop (no re-prompt).
- `status == "completed"` on load -> reported as completed with its summary.
- Two windows pointing at the same directory MUST NOT share/corrupt state:
  each window uses a unique `session_id` and its own `goal.json`
  (`.ziki/goal.<session_id>.json`) so windows stay isolated.

## Repository interface

```
GoalRepository = struct {
    ctx: *anyopaque,
    vtable: *const VTable,
};
VTable = struct {
    save: fn (ctx: *anyopaque, alloc: Allocator, goal: Goal) anyerror!void,
    load: fn (ctx: *anyopaque, alloc: Allocator) anyerror!?Goal,
};
```
`FsGoalRepository` implements it over the injected `fs.Fs` (DIP).
