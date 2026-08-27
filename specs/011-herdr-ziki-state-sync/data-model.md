# Data Model: Herdr ↔ Ziki Agent-State Integration

**Feature**: 011-herdr-ziki-state-sync | **Date**: 2026-08-27

## Entities

### Ziki `AgentState` (published state)
The enumerated state Ziki maintains and publishes for its active session.

| Field | Type | Notes |
|---|---|---|
| `idle` | enum variant | no active goal / goal ended or process exiting |
| `working` | enum variant | goal loop is executing turns |
| `blocked` | enum variant | goal stuck pending attention (criterion not satisfiable) |

- Single per process/session (Ziki runs one goal per process).
- `toHerdr()` maps → Herdr `AgentState`: `idle→Idle`, `working→Working`,
  `blocked→Blocked` (research.md R4).

### `PaneReportParams` (the push payload)
The structured body Ziki sends to Herdr's `pane report agent` API.

| Field | Type | Required | Source |
|---|---|---|---|
| `pane_id` | string | yes | `HERDR_PANE_ID` env |
| `source` | string | yes | fixed `"herdr:ziki"` |
| `agent` | string | yes | fixed `"ziki"` |
| `state` | string | yes | Ziki `AgentState` lowercased |
| `message` | string | optional | human-readable context (e.g. why blocked) |
| `seq` | integer | yes | monotonic per-process counter |
| `agent_session_id` | string | optional | `goal.id` |
| `agent_session_path` | string | optional | `state_dir` |

### `HerdrReporter` (DI interface)
The boundary Ziki depends on to push state. Mirrors the repo's `Provider` /
`Transport` vtable pattern.

```
HerdrReporter { ctx, vtable: { report(ctx, alloc, params) !void } }
```

- `HerdrHttpClient` — concrete impl over the existing `Transport` interface,
  POSTs JSON `PaneReportParams` to `${HERDR_API_URL}/api/v1/pane/report/agent`.
- `FakeHerdrReporter` — scripted in-memory impl for tests (records published
  params, can be made to fail to exercise error handling).

### `StatePublisher`
Owns the publication side-effects. Injected into `GoalExecutor`.

| Field | Type | Notes |
|---|---|---|
| `reporter` | `?HerdrReporter` | null → screen/OSC only (FR-008) |
| `writer` | `std.io.AnyWriter` | stdout sink for marker + OSC; injected in tests |
| `pane_id` | `[]const u8` | from `HERDR_PANE_ID` |
| `source` | `[]const u8` | `"herdr:ziki"` |
| `agent` | `[]const u8` | `"ziki"` |
| `session_id` | `[]const u8` | `goal.id` (set after `Goal.init`) |
| `session_path` | `[]const u8` | `state_dir` |
| `seq` | `u64` | monotonic, incremented on every `publish` |

Method: `publish(state, message?) !void` — increments `seq`, pushes
`PaneReportParams` when `reporter != null` (errors swallowed, never crashes),
and always emits the screen marker + OSC title to `writer`.

## State Machine

### Ziki publishable state
```
        (goal starts)
             │
             ▼
         [working]  ──── (goal.status == .blocked) ───▶ [blocked]  (terminal: awaiting attention)
             │
             └──── (goal ends / exits) ───────────────▶ [idle]     (terminal)
```

`idle` is also the initial state before any goal starts (the process is live but
has no active goal).

### Ziki `goal.status` → published `AgentState`
| `goal.status` | Published `AgentState` | `message` |
|---|---|---|
| (pre-run) | `working` | — (set by `runGoal` before `ex.run`) |
| `.active` (each turn) | `working` | — |
| `.completed` | `idle` (terminal) | `"completed"` |
| `.aborted` | `idle` (terminal) | `"aborted: <reason>"` |
| `.blocked` | `blocked` (terminal) | `"could not satisfy criterion: <criterion>"` |

## State Transitions (validation rules)

- **T1 (start → working)**: on `runGoal`, before `ex.run`, `publish(.working)`.
- **T2 (active → blocked)**: when executor sets `.blocked`, `publish(.blocked, msg)`.
- **T3 (active → completed)**: when executor sets `.completed`, `publish(.idle, "completed")`.
- **T4 (active → aborted)**: when executor sets `.aborted`, `publish(.idle, "aborted: <reason>")`.
- **T5 (monotonic seq)**: every `publish` increments `seq`; no two publishes share a `seq`; later transitions carry strictly greater `seq` (SC-006).
- **T6 (degrade)**: when `HERDR_PANE_ID` is absent, `reporter = null`; `publish` still emits screen marker + OSC and never errors out (FR-008).
- **T7 (error isolation)**: if `reporter.report` fails, `publish` swallows the error and still emits screen marker + OSC (FR-008, push is best-effort).

## Key Relationships

- `StatePublisher` → `HerdrReporter` (depends on interface, not impl — DIP).
- `StatePublisher` → `std.io.AnyWriter` (stdout sink, injected).
- `GoalExecutor` → `?StatePublisher` (optional collaborator, default `null` — OCP).
- `main.zig` → constructs `StatePublisher` from env, injects into `GoalExecutor`, sets `session_id`/`session_path` from the `Goal`.
