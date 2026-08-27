# Implementation Plan: Herdr ↔ Ziki Agent-State Integration

**Branch**: `011-herdr-ziki-state-sync` | **Date**: 2026-08-27 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/011-herdr-ziki-state-sync/spec.md`

## Summary

Ziki (a Zig goal-CLI agent) must publish its live agent state to Herdr so that
Forklift — which drives Ziki through Herdr panes — can coordinate Ziki panes by
their actual state (working / blocked / idle) without scraping transcripts.

The integration reuses Herdr's **already-shipped** agent-state contract: Ziki
maintains an explicit enumerated state, **pushes** it to Herdr's `pane report
agent` API (authoritative), and additionally emits **screen markers + OSC
sequences** as a fallback so Herdr's `ziki.toml` manifest can still classify the
pane when the push path is unavailable. State transitions are hooked at the exact
points `GoalExecutor` already changes `goal.status`, so Ziki's goal-execution
logic is unchanged (Open/Closed, per the constitution).

## Technical Context

**Language/Version**: Zig 0.15.2 (matches the rest of the repo; `zig build test` is the suite runner).

**Primary Dependencies**: none new. Reuses the existing `Provider`/`Transport` vtable DI pattern (`src/provider/provider.zig`, `src/provider/transport.zig`). No third-party or HTTP dependency is added — `HerdrHttpClient` is built on the same `Transport` interface the model providers already use.

**Storage**: no new persistence. Pane/session identity is derived from the environment (`HERDR_PANE_ID`) and the existing per-run `state_dir` / `goal.id`.

**Testing**: Zig's built-in `test` blocks, aggregated by `tests.zig` and run via `zig build test` (no single-test or per-file filter — see `.specify/memory/tdd-profile.md`). Fakes implement injected interfaces (`FakeHerdrReporter`, a capturing `std.io.AnyWriter` sink) exactly like `FakeProvider`/`FakeFs`.

**Target Platform**: macOS / Linux CLI; localhost/loopback Herdr instances in scope for v1 (remote Herdr not separately tested, but not excluded).

**Project Type**: CLI / autonomous agent (single binary, `src/main.zig` composition root).

**Performance Goals**: state publication must add negligible overhead to the goal loop; push is best-effort and must never stall or crash a turn (FR-008). SC-001 target of <2s state propagation is owned by Herdr, not Ziki.

**Constraints**:
- No change to goal-execution *logic* (constitution Open/Closed + Interface Segregation). Publication is a side-effect added behind the composition root.
- No new network calls to model providers; the Herdr push is a separate `Transport` client.
- Must not crash when `HERDR_PANE_ID` is absent or Herdr's API is unreachable; degrades to screen/OSC-only.

**Scale/Scope**: one `AgentState` per process/session (Ziki runs one goal per process). State is per-pane, never global.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

The ziki constitution (`.specify/memory/constitution.md`) is enforced:

- **Principle I (SOLID, no exceptions)**:
  - **SRP** — `StatePublisher` owns only state-publication side-effects; `HerdrHttpClient` owns only the HTTP push; `GoalExecutor` still owns only the goal loop. No "god module".
  - **OCP** — Publication is added as a new optional collaborator (`publisher: ?StatePublisher = null`) injected into `GoalExecutor`; the executor's control flow and outcomes are untouched. Existing tests that omit `publisher` keep the default `null` and stay green.
  - **DIP** — `StatePublisher` depends on the `HerdrReporter` interface, not on `HerdrHttpClient`; tests inject `FakeHerdrReporter`. The stdout sink is injected as `std.io.AnyWriter`.
  - **ISP / LSP** — `HerdrReporter` exposes exactly one method (`report`); `HerdrHttpClient` and `FakeHerdrReporter` are substitutable.
- **Principle II (Dependency Injection, doubles via fakes)** — all external boundaries (Herdr API, stdout) are injected; tests go through fakes, never real network or `std.fs.stdout`.
- **Governance** — No new config schema beyond the two environment variables (`HERDR_PANE_ID`, `HERDR_API_URL`); existing config precedence (env > file) is preserved.

No gate violations. Complexity Tracking table not needed (no new projects, no pattern beyond those already in the repo).

## Project Structure

### Documentation (this feature)

```text
specs/011-herdr-ziki-state-sync/
├── plan.md              # This file
├── research.md          # Phase 0 (contract assumptions resolved)
├── data-model.md        # Phase 1 (entities, state machine, transitions)
├── quickstart.md        # Phase 1 (how to validate end-to-end)
├── contracts/           # Phase 1 (the Herdr integration boundary)
│   └── herdr-agent-state.md
└── tasks.md             # Phase 2 (/skill:speckit-tasks output)
```

### Source Code (repository root)

```text
src/
├── agent/
│   ├── executor.zig     # CHANGED: publisher hook at each goal.status transition (no logic change)
│   ├── state.zig        # NEW: AgentState, PaneReportParams, HerdrReporter iface, StatePublisher
│   └── herdr.zig        # NEW: HerdrHttpClient (Transport-backed push) + FakeHerdrReporter
├── config/config.zig    # UNCHANGED (HERDR_* read via env in main.zig, not config.json)
├── main.zig             # CHANGED: build StatePublisher from HERDR_PANE_ID / HERDR_API_URL, pass to executor
└── ... (existing modules unchanged)
tests.zig                # CHANGED: aggregate src/agent/state.zig and src/agent/herdr.zig
```

**Structure Decision**: single-project CLI (the repo default). New code lives under `src/agent/` alongside `executor.zig`, reusing the existing DI conventions (`vtable` structs, fakes, `tests.zig` aggregator). No new directory tier.

## Complexity Tracking

> Not used — no constitution gate violations requiring justification.
