---
feature: 011-herdr-ziki-state-sync
loop: outside-in
profile: .specify/memory/tdd-profile.md
spec_criteria: 8 # functional requirements FR-001..FR-008 (success criteria SC-001..SC-006)
planned_at: 9376b03
updated_at: 9376b03
suite_baseline: green # 65 passed, 0 failed at completion (40 baseline + 25 herdr/state-sync)
---

# Test List: Herdr ↔ Ziki Agent-State Integration

## Outer loop: acceptance behaviors

No dedicated acceptance runner exists (see `.specify/memory/tdd-profile.md`):
the highest level this repo can test is an **integration test against the composed
modules** (GoalExecutor + StatePublisher + fakes). Each `A` behavior is hosted
there and is the test that fails when the units are individually right but
collectively wrong. US1-4 (death → `unknown`) and US4-1/2 (Herdr sidebar badges)
are cross-repo Herdr concerns and are recorded in **Out of scope**.

| id  | behavior | traces | kind | state | test |
| --- | --- | --- | --- | --- | --- |
| A1 | Mid-goal, Ziki pushes `working` with full `PaneReportParams` (source=`herdr:ziki`, agent=`ziki`, pane_id, monotonic seq, session id/path) and emits working screen marker + OSC | SC-001, FR-001, FR-002 | example | DONE | src/agent/state_sync_test.zig:201 |
| A2 | On blocked (await input), Ziki pushes `blocked` with a `message` and emits blocked screen marker + OSC | SC-002, FR-002, FR-006 | example | DONE | src/agent/state_sync_test.zig:248 |
| A3 | On goal end/exit, Ziki pushes a terminal `idle` report (no stale `working`) | SC-001, FR-006 | example | DONE | src/agent/state_sync_test.zig:288 |
| A4 | With the push path disabled (no `HERDR_PANE_ID`), Ziki still emits `working`/`blocked`/`idle` screen markers + OSC title and does not crash | SC-004, FR-003, FR-004, FR-008 | example | DONE | src/agent/state_sync_test.zig:319 |
| A5 | Across rapid transitions, every pushed `seq` is strictly greater than the previous; no stale report can win | SC-006, FR-002 | example | DONE | src/agent/state_sync_test.zig:348 |

## Inner loop: unit behaviors

Grouped by the component from `plan.md` that owns them.

### `src/agent/state.zig`

| id  | behavior | traces | kind | state | test |
| --- | --- | --- | --- | --- | --- |
| U1 | `AgentState` enum has `idle`/`working`/`blocked` and `toHerdr()` maps idle→Idle, working→Working, blocked→Blocked | FR-001, FR-005 | example | DONE | src/agent/state.zig:187 |
| U2 | `AgentState` can represent the undetermined/`Unknown` emission path (boundary: state cannot be resolved) | FR-005 | example | DONE | src/agent/state.zig:193 |
| U3 | `StatePublisher.publish(state, message?)` builds `PaneReportParams` (pane_id, source=`herdr:ziki`, agent=`ziki`, state, seq, agent_session_id, agent_session_path) and pushes via `HerdrReporter` | FR-002 | example | DONE | src/agent/state.zig:197 |
| U4 | `seq` is strictly increasing: first publish ≥ 1, each subsequent `>` previous (both sides of the boundary) | SC-006, FR-002 | example | DONE | src/agent/state.zig:216 |
| U5 | `publish` emits the screen marker `[ziki-state: <state>]` for working/blocked/idle on the injected `std.io.AnyWriter` | FR-003 | example | DONE | src/agent/state.zig:232 |
| U6 | `publish` emits the OSC title `\x1b]2;ziki:<state>\x07` on the injected `std.io.AnyWriter` | FR-004 | example | DONE | src/agent/state.zig:244 |
| U7 | Marker/OSC include the `message` when present (blocked w/ message) and omit it when absent (idle/working) — both sides | FR-003, FR-004 | example | DONE | src/agent/state.zig:256 |
| U8 | With `reporter = null` (no pane id), `publish` still emits marker + OSC and never attempts a push or crashes | FR-008 | example | DONE | src/agent/state.zig:272 |
| U9 | When `reporter.report` returns an error, `publish` swallows it and still emits marker + OSC (specific failure isolated) | FR-008 | example | DONE | src/agent/state.zig:282 |
| U10 | Push is authoritative and consistent: for every state, the pushed `state` equals the on-screen marker's state (FR-007) | FR-007 | example | DONE | src/agent/state.zig:296 |

### `src/agent/herdr.zig`

| id  | behavior | traces | kind | state | test |
| --- | --- | --- | --- | --- | --- |
| U11 | `HerdrHttpClient` serializes `PaneReportParams` to the exact contract §2 JSON body and POSTs to `${HERDR_API_URL}/api/v1/pane/report/agent` with `Content-Type: application/json` over a fake `Transport` | FR-002 | contract | DONE | src/agent/herdr.zig:124 |
| U12 | `HerdrHttpClient` defaults `HERDR_API_URL` to `http://localhost:7878` when the env var is unset (boundary: env set vs unset) | FR-002 | example | DONE | src/agent/herdr.zig:171 |
| U13 | `FakeHerdrReporter` records the last published `PaneReportParams` (and can be forced to fail) so unit tests assert pushes without a network | FR-002 | example | DONE | src/agent/herdr.zig:314 |

### `src/agent/executor.zig`

| id  | behavior | traces | kind | state | test |
| --- | --- | --- | --- | --- | --- |
| U14 | With a `publisher` set, the executor publishes `working` at the start of `run` (T1) | FR-001, FR-002 | example | DONE | src/agent/state_sync_test.zig:51 |
| U15 | The executor publishes a terminal `idle` when the goal completes (T3) | FR-006 | example | DONE | src/agent/state_sync_test.zig:80 |
| U16 | The executor publishes a terminal `idle` when the goal aborts (stop signal / budget) (T4) | FR-006 | example | DONE | src/agent/state_sync_test.zig:108 |
| U17 | The executor publishes `blocked` (with a `message`) when the goal becomes blocked (T2) | FR-002, FR-006 | example | DONE | src/agent/state_sync_test.zig:142 |
| U18 | With `publisher` omitted (`null`), the executor runs to completion unchanged — existing executor tests stay green, no publish attempted (SC-005, backward compatibility) | SC-005 | characterization | DONE | src/agent/state_sync_test.zig:182 |

### `src/main.zig`

| id  | behavior | traces | kind | state | test |
| --- | --- | --- | --- | --- | --- |
| U19 | `runGoal` reads `HERDR_PANE_ID` → builds a `StatePublisher` with a real reporter; when absent, builds one with `reporter = null` (boundary: present vs absent) (FR-008) | FR-008 | example | DONE | src/main.zig:472 |

## Invariants and edge cases still to place

- A Ziki pane that dies without a terminal report: Herdr's detection window must
  resolve it to `unknown` (SC-003). This is owned by Herdr's detection, not Ziki
  code — tracked in the Herdr fork; no Ziki test can exercise it (see Out of scope).
- `pane_id` is per-pane and never global (spec edge case): each `PaneReportParams`
  carries the process's `HERDR_PANE_ID`; covered structurally by U3 + U19.

## Out of scope

- **US1-4 / SC-003 (death → `unknown`)**: resolved by Herdr's detection window in
  the Herdr fork, not Ziki code. Ziki's responsibility is only the terminal `idle`
  push on a *clean* exit (FR-006 / U15 / U16). No in-repo test is possible.
- **US4-1 / US4-2 (Herdr sidebar badges)**: purely a Herdr UI concern satisfied by
  the published state (FR-001…FR-008) plus the Herdr-side `Agent::Ziki` variant and
  `ziki.toml` manifest (cross-repo partner). No Ziki code change.
- **TLS / remote Herdr**: only loopback `http://localhost:*` is in v1 scope; remote
  Herdr transport is not separately tested (research.md R2).

## Verification commands

Copied verbatim from `.specify/memory/tdd-profile.md` at planning time, so this
file is readable on its own. The profile marks `single` and `file` as `null`, so
the loop MUST run the full suite for every red/green check (no per-test filter).

- Single test: **unavailable** (`--test-filter` is a silent false-green in this
  Zig 0.15.2 build — it reports "All 0 tests passed" for every input). The loop
  runs the whole suite instead.
- File: **unavailable** (every module uses `../` relative imports that fail
  standalone). The loop runs the whole suite instead.
- Full suite: `zig build test` (equivalent: `zig test tests.zig`)
- Coverage: `kcov --include-pattern=src/ <out-dir> .zig-cache/o/<hash>/test`
  (get hash via `ls -t .zig-cache/o/*/test | head -1`; do NOT pass `--listen=-`)
- Mutation: **none** installed; audit uses deliberate mutants instead.
- Property-based: **none**; invariants (U4, U10) are sampled boundary examples.
- Acceptance / E2E runner: **none**; outer behaviors (A*) are hosted as composed
  integration tests (see Outer loop note).

## Baseline

- suite: `zig test tests.zig` → 65 passed, 0 failed (40 baseline + 25 herdr/state-sync)
- build: `zig build` → 0 errors (production binary compiles)
- commit: `9376b03`
- recorded: all 24 behaviors DONE; 30/30 tasks ticked
