# Data Model: Zig Goal CLI (ziki)

Entities derived from spec FR-001..FR-010 and the Key Entities section. All
types are plain Zig structs serialized with `std.json` where persisted.

## Entities

### Goal (value type — `goal/goal.zig`)

The unit of autonomous work (spec Key Entity: Goal).

| Field | Type | Notes |
|-------|------|-------|
| id | `[]const u8` | Unique session-scoped id |
| objective | `[]const u8` | Natural-language objective (FR-001) |
| criterion | `?[]const u8` | Optional explicit completion criterion (FR-001) |
| status | `enum { active, completed, blocked, aborted }` | FR-003 |
| progress | `[]const u8` | Human-readable progress indicator (FR-003) |
| budgets | `Budgets` | turns / tokens / time caps (spec edge case) |
| created_at | `i64` | epoch ms |
| updated_at | `i64` | epoch ms |
| session_id | `[]const u8` | owning window (FR: isolation across windows) |

**State transitions** (FR-003, FR-008, spec edge cases):
`active -> completed` (criterion met / model stops), `active -> blocked`
(unreachable, options exhausted), `active -> aborted` (`/stop` or budget
exceeded). `completed/blocked/aborted` are terminal; resume reloads `active`.

### Budgets (`goal/goal.zig`)

| Field | Type | Default |
|-------|------|---------|
| max_turns | `u32` | 50 |
| max_tokens | `u64` | 200_000 |
| max_seconds | `u64` | 1800 |

Exceeding any budget -> `aborted` with partial summary (spec edge case).

### Provider (config + runtime — `provider/provider.zig`, `config/config.zig`)

| Field | Type | Notes |
|-------|------|-------|
| name | `enum { opencode, kilo, zai, kimi, openai_custom }` | FR-004 |
| kind | = name | one of the five required |
| endpoint | `[]const u8` | base URL (preset default) |
| model | `[]const u8` | selected model |
| api_key | `?[]const u8` | credentials (FR-005) |

### ChatMessage / ChatResponse (`provider/provider.zig`)

- `ChatMessage { role: enum{ system, user, assistant, tool }, content: []const u8, tool_calls: ?[]ToolCall, tool_call_id: ?[]const u8 }`
- `ToolCall { id: []const u8, name: []const u8, arguments_json: []const u8 }`
- `ChatResponse { message: ChatMessage, finish_reason: enum{ stop, tool_calls, length } }`

### ToolResult (`tool/tool.zig`)

`{ ok: bool, output: []const u8, error_message: ?[]const u8 }`

## Relationships

```
Session/Window ──owns 1──> Goal (active or none)
Goal ──uses──> Provider (injected, 1 active)
GoalExecutor ──drives──> Goal
GoalExecutor ──calls──> Provider (complete)
GoalExecutor ──calls──> Tool[] (execute on ToolCall)
Goal ──persisted by──> GoalRepository ──uses──> Fs
Provider ──uses──> Transport (HttpTransport or fake)
Tool (read/edit/search/bash) ──uses──> Fs
```

## Validation rules (from requirements)

- `objective` MUST be non-empty; empty/malformed `/goal` is rejected (spec edge
  case) before any work begins.
- A `Goal` MUST NOT be `completed` without either a model stop or a satisfied
  criterion.
- Provider list is exactly the five; any other provider name is a config error.
- No provider configured or invalid credentials -> `FR-010` clear error, no goal
  work starts.

## Persistence format (`goal-state-schema.md` in contracts/)

`Goal` serialized to `.ziki/goal.json` exactly as the struct fields above
(enum as string, timestamps as epoch ms). `GoalRepository.load` is resilient:
missing file -> `null` (fresh goal); corrupt file -> clear error, never silent.
