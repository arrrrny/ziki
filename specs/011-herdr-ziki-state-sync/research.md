# Research: Herdr ↔ Ziki Agent-State Integration

**Feature**: 011-herdr-ziki-state-sync | **Date**: 2026-08-27

This document resolves the open questions from the Technical Context so the design
below can be concrete.

## R1. The Herdr agent-state contract (extracted from `Developer/herdr`, master `1f8db18d`)

Herdr already defines how it learns an agent's state. Three detection paths, all
gated on Herdr recognizing the agent by process name:

1. **Screen manifest** — a bundled `src/detect/manifests/<agent>.toml` with
   `[[rules]]` carrying `state` (`working` | `blocked`), `priority`, a `region`
   of bottom-of-buffer text, and `contains`/`any`/`all`/`not` gates.
2. **OSC title/progress** — rules may set `region = "osc_title"` /
   `"osc_progress"`, reading the agent's OSC escape sequences directly.
3. **Programmatic `pane report agent` API** — the agent pushes a structured
   `PaneReportAgentParams { pane_id, source, agent, state, message?, seq?,
   agent_session_id?, agent_session_path? }`. This is the authoritative path;
   Herdr trusts it when `source` carries lifecycle authority (`herdr:kimi`,
   `herdr:kilo`).

Herdr's state model is `AgentState = { Idle, Working, Blocked, Unknown }`, read
per pane via `herdr agent read <pane> --source detection --format json` and
`herdr agent explain <pane> --json`. **Today there is no `Ziki` agent variant**,
so a Ziki pane is currently `Unknown`.

**Decision**: Ziki implements FR-001…FR-008 against this exact contract. The
Herdr-side additions (`Agent::Ziki`, `ziki.toml` manifest, `herdr:ziki` authority)
are a cross-repo dependency tracked in `Developer/herdr` and recorded in the spec
"Dependencies / Contract Partner" section. Ziki's publication is complete and
testable against the `pane report agent` API regardless of whether the Herdr-side
manifest has landed.

## R2. Exact HTTP endpoint for the `pane report agent` push

**Question**: what is the concrete URL + method Herdr exposes?

**Finding**: Herdr's `pane report agent` API already ships in the fork, but its
exact route/path is defined in the Herdr repo, not Ziki, and the fork was
analyzed from the host checkout (`Developer/herdr`) without live API introspection.
The repo's server layer was not exhaustively traced for the verbatim path.

**Decision (documented assumption, not a guess that affects Ziki correctness)**:
Ziki POSTs a JSON `PaneReportAgentParams` body to
`${HERDR_API_URL}/api/v1/pane/report/agent` where `HERDR_API_URL` defaults to
`http://localhost:7878` (Herdr's conventional local port). The exact path is
**configurable via env** and is the single contract seam; if Herdr's real route
differs by path only, it is a one-line change in `HerdrHttpClient` with no
downstream impact. The `source` field is fixed to `"herdr:ziki"` to mirror
`herdr:kimi` / `herdr:kilo` authority. The request body schema is fixed by the
contract (R1) and is what Ziki must produce exactly.

## R3. Where Ziki's state actually transitions in the current code

`GoalExecutor.run()` (src/agent/executor.zig) is the only place `goal.status`
changes. Observed transitions:

- start → `active` (set by caller via `emitStatus(.active)` in `main.zig`)
- `active` → `aborted` (user `/stop` signal, or turn budget exceeded)
- `active` → `completed` (criterion satisfied, or no criterion and model stopped)
- `active` → `blocked` (criterion not satisfied after 3 verify retries)

**Decision**: the `working`/`idle`/`blocked` publication maps onto these
transitions (see data-model.md). The push is a side-effect added at each
assignment; the executor's outcomes are unchanged (OCP).

## R4. Mapping Ziki state → Herdr `AgentState`

| Ziki publishable state | Herdr `AgentState` | Trigger in Ziki |
|---|---|---|
| `idle` | `Idle` | before a goal starts (no active goal) and after a goal ends/exits |
| `working` | `Working` | goal loop executing turns (`goal.status == .active`) |
| `blocked` | `Blocked` | `goal.status == .blocked` (could not satisfy criterion) |
| (unrecoverable) | `Unknown` | reserved; Ziki always knows its own state, but the publisher can emit `Unknown` if it cannot determine one |

Note: Ziki's executor is fully autonomous today — it has no mid-run
"await human approval" yield point. The spec's "awaiting input" maps onto the
`blocked` terminal state (the agent is stuck pending attention). If Ziki later
gains an explicit await-input point, it calls `publisher.publish(.blocked, msg)`
at that point; the publisher already supports it.

## R5. Screen marker + OSC format (FR-003 / FR-004)

**Decision**:
- **Screen marker** (plain text, grep-able, emitted on its own line):
  `[ziki-state: <state>]` with optional trailing ` <message>` when a message
  exists, e.g. `[ziki-state: blocked] criterion not satisfied after retries`.
  This is the token the Herdr `ziki.toml` manifest's `contains`/`line_regex`
  rules match in the `bottom_lines(N)` / `whole_recent` regions.
- **OSC title** (escape sequence): `\x1b]2;ziki:<state>\x07` — read by Herdr's
  `osc_title` region. The `ziki.toml` manifest may set
  `region = "osc_title"` rules to classify from this sequence.

Both are emitted on every `publish` so push and fallbacks stay consistent
(FR-007).

## R6. Pane / session identity (FR-002 / FR-008)

- `pane_id` ← `HERDR_PANE_ID` env var (Herdr sets this for panes it manages).
- `agent_session_id` ← `goal.id` (unique per run, already generated in
  `Goal.init`).
- `agent_session_path` ← `state_dir` (the process's `.ziki` directory).
- If `HERDR_PANE_ID` is absent, `reporter = null` and Ziki degrades to
  screen/OSC-only; it MUST NOT crash (FR-008).
