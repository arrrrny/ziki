# Feature Specification: Herdr ↔ Ziki Agent-State Integration

**Feature Branch**: `011-herdr-ziki-state-sync`

**Created**: 2026-08-27

**Status**: Draft

**Input**: User description: "since the next version of forklift will work directly using herdr panes for communication, it is extremely important that herdr knows the ziki agent state, pull the latest herdr from our fork in Developer/herdr analyze its kimi-code integration and how it communicates and tracks agent state, and if there is a contract apply that contract requirements for ziki and create a spec on herdr to integrate with ziki"

## Background — the Herdr contract (what "knows the agent state" means)

This feature applies Herdr's existing **agent-state detection contract** to Ziki. The
contract was extracted by analyzing the Herdr fork at `Developer/herdr` (master at
`1f8db18d`). Herdr learns an agent's state through three complementary paths, all
gated on Herdr first *recognizing the agent by process name*:

1. **Screen manifest (passive).** A bundled TOML manifest
   (`src/detect/manifests/<agent>.toml`) defines `[[rules]]`, each carrying a
   `state` (`working` | `blocked`), `priority`, a `region` of the pane's
   bottom-of-buffer text, and `contains` / `any` / `all` / `not` gates (with
   `line_regex`). Herdr matches the pane snapshot against these rules to infer
   state. Regions include `whole_recent`, `bottom_lines(N)`,
   `bottom_non_empty_lines(N)`, `above_prompt_box`, and the OSC regions
   `osc_title` / `osc_progress`.
2. **OSC title/progress (active).** A rule may set `region = "osc_title"` or
   `region = "osc_progress"`, so an agent that emits terminal OSC escape
   sequences (title / progress) has its state read directly from those strings.
3. **Programmatic pane-report (authoritative).** Herdr exposes a `pane report
   agent` API. An agent pushes a structured
   `PaneReportAgentParams { pane_id, source, agent, state, message?, seq?,
   agent_session_id?, agent_session_path? }` to Herdr. This is the highest-authority
   path: Herdr trusts it for lifecycle state when `source` carries lifecycle
   authority (e.g. `herdr:kimi`, `herdr:kilo`).

Herdr's state model is the enum `AgentState = { Idle, Working, Blocked, Unknown }`.
External tools read it per pane via `herdr agent read <pane> --source detection
--format json` and `herdr agent explain <pane> --json`, and via Herdr's API/event
stream. **Today Herdr has no `Ziki` agent variant**, so a Ziki pane is currently
detected as `Unknown` (plain program). Closing that gap is the substance of this
feature.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Forklift coordinates Ziki panes by their live state (Priority: P1)

As the operator of Forklift (the multi-agent orchestrator), I run many Ziki agents
inside Herdr panes. I need Herdr to report, for each Ziki pane, whether Ziki is
**working** (executing goal turns), **blocked** (awaiting my input / approval), or
**idle** (no active goal / finished), so Forklift can decide when to dispatch new
work, when to wait, and when to prompt me — without scraping Ziki's transcript.

**Why this priority**: This is the entire reason the feature exists. Forklift's next
version communicates through Herdr panes, and "know the Ziki agent state" is the
blocking prerequisite for that coordination.

**Independent Test**: Launch Ziki in a Herdr pane, drive it through a goal that hits
an approval/await-input point, and confirm `herdr agent explain <pane> --json`
reports `blocked` at that point and `working` while executing, and `idle` once the
goal ends — without Forklift parsing any free-form text.

**Acceptance Scenarios**:

1. **Given** a Ziki pane is mid-goal executing turns, **When** Herdr is queried, **Then** the pane's detected state is `working`.
2. **Given** a Ziki pane is awaiting human input (approval / stop / clarification), **When** Herdr is queried, **Then** the pane's detected state is `blocked` with a visible blocker.
3. **Given** a Ziki pane has no active goal or the goal has ended, **When** Herdr is queried, **Then** the pane's detected state is `idle`.
4. **Given** a Ziki pane whose process died, **When** Herdr's detection window elapses, **Then** the pane's state becomes `unknown` and is never stuck on `working`.

---

### User Story 2 - Ziki publishes its state to Herdr authoritatively (Priority: P1)

As Ziki, I want to push my current state to Herdr through the `pane report agent`
API the moment it changes, so Herdr (and therefore Forklift) is always current —
even mid-turn, where screen scraping would lag or miss a transition.

**Why this priority**: The pane-report push is the only path that gives Herdr
immediate, structured, unambiguous state. Screen/OSC detection is a redundancy, not
the source of truth.

**Independent Test**: With the `pane report agent` API available, transition Ziki
from `idle` → `working` → `blocked` → `idle` and confirm Herdr records each
transition (demonstrable via `herdr agent read <pane> --source detection --format json`)
within the detection window, carrying the goal session id so the state is tied to a
specific goal.

**Acceptance Scenarios**:

1. **Given** Ziki begins executing a goal, **When** the state becomes `working`, **Then** Ziki pushes a pane-report with `state=working`, `source="herdr:ziki"`, `agent="ziki"`, the pane id, a monotonic `seq`, and the goal `agent_session_id`/`path`.
2. **Given** Ziki reaches an await-input point, **When** the state becomes `blocked`, **Then** Ziki pushes a pane-report with `state=blocked` and a `message` describing what it is waiting on.
3. **Given** the goal ends or Ziki exits, **When** the session closes, **Then** Ziki pushes a terminal `idle` report so Herdr does not retain a stale `working` state.

---

### User Story 3 - Ziki stays detectable without the push path (Priority: P2)

As Ziki, I want Herdr to still infer my state from my terminal output and OSC
sequences when the `pane report agent` API is unavailable (e.g. Herdr's API server
is not running, or Ziki was launched in a plain pane). This is the fallback that
keeps Forklift functional in degraded environments.

**Why this priority**: Robustness. The push path is preferred, but detection must
not silently break when it is absent.

**Independent Test**: Disable the push path, run Ziki so it emits its status markers
and OSC title, and confirm a Herdr `ziki.toml` manifest still classifies the pane as
`working` / `blocked` / `idle` from the screen/OSC regions.

**Acceptance Scenarios**:

1. **Given** the push path is unavailable, **When** Ziki prints its working marker, **Then** Herdr's `ziki.toml` manifest matches and reports `working`.
2. **Given** the push path is unavailable, **When** Ziki prints its await-input marker, **Then** Herdr reports `blocked`.
3. **Given** Ziki emits an OSC title carrying its state, **When** Herdr reads the `osc_title` region, **Then** the reported state matches the emitted value.

---

### User Story 4 - A human watching Herdr sees Ziki's live status (Priority: P3)

As a human watching the Herdr UI, I want each Ziki pane's sidebar to show a live
`working` / `blocked` / `idle` badge, so I can see at a glance which agents need my
attention.

**Why this priority**: Nice-to-have operator visibility; it falls out of the same
detection data the other stories rely on.

**Independent Test**: Run a Ziki goal that blocks on input and confirm the Herdr
sidebar shows the `blocked` indicator on that pane.

**Acceptance Scenarios**:

1. **Given** a Ziki pane is `blocked`, **When** the human views the Herdr sidebar, **Then** the pane shows a blocked indicator.
2. **Given** a Ziki pane is `working`, **When** the human views the Herdr sidebar, **Then** the pane shows a working indicator.

---

### Edge Cases

- **Process not recognized.** Until Herdr adds a `Ziki` agent variant + `ziki.toml` manifest (cross-repo dependency, tracked in the Herdr fork), a Ziki pane is detected as `unknown`. The spec does not claim detection works before that lands.
- **Crash / kill.** Ziki did not get to push a terminal report. Herdr MUST fall back to `unknown` (not stuck `working`) within its detection window; Ziki SHOULD push `idle` on a clean exit.
- **Multiple Ziki panes.** Each pane is reported by its own `pane_id`; state is per-pane, never global.
- **State flap.** Rapid transitions (working↔idle while tools run) MUST be ordered by monotonic `seq` so Herdr applies the latest, not the stale, report.
- **Empty / unset proxy and other config** is irrelevant here; this feature only concerns state publication, not transport.
- **Push path and screen markers disagree.** The push (pane-report) is authoritative; screen/OSC detection is a redundancy that Herdr arbitrates by source priority. Ziki MUST keep both consistent.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Ziki MUST maintain an explicit, enumerated agent state for its active session with values `idle`, `working`, and `blocked`, and MUST transition it as the goal progresses (start → `working`; await input → `blocked`; end/exit → `idle`).
- **FR-002**: Ziki MUST publish its current state to Herdr through the `pane report agent` API whenever the state changes, supplying `pane_id`, `source = "herdr:ziki"`, `agent = "ziki"`, the `state`, an optional human-readable `message`, a monotonic `seq`, and the goal `agent_session_id` / `agent_session_path` so the state is tied to a specific goal.
- **FR-003**: Ziki MUST emit a stable, screen-detectable status marker on stdout covering at least the `working`, `blocked` (awaiting input), and `idle`/`done` states, so a Herdr `ziki.toml` manifest can match it as a fallback when the push path is unavailable.
- **FR-004**: Ziki MUST emit an OSC title (and/or progress) sequence carrying its current state, so Herdr's `osc_title` / `osc_progress` detection regions classify the pane as a second fallback.
- **FR-005**: Ziki's state vocabulary MUST map unambiguously onto Herdr's `AgentState` (`Idle`, `Working`, `Blocked`, `Unknown`): `idle`→`Idle`, `working`→`Working`, `blocked`→`Blocked`, and any unrecoverable/unknown condition→`Unknown`.
- **FR-006**: On clean goal end or process exit, Ziki MUST publish a terminal `idle` report (push) so Herdr does not retain a stale `working` state; on ungraceful exit Herdr's detection window resolves the pane to `unknown`.
- **FR-007**: Ziki MUST treat the pane-report push as the authoritative state source and screen/OSC markers as redundancy only — it MUST NOT require Herdr (or Forklift) to parse free-form transcript text to determine state.
- **FR-008**: Ziki MUST discover the pane it runs in (e.g. via the `HERDR_PANE_ID` environment variable Herdr sets for panes) so every push and marker is attributable to the correct pane; if no pane id is available, Ziki MUST degrade to screen/OSC-only detection and MUST NOT crash.

### Key Entities *(include if feature involves data)*

- **Ziki Agent State**: an enumerated value `{ idle, working, blocked }` plus an optional `message` (what Ziki is waiting on / doing). Single per process/session.
- **Herdr AgentState**: the contract enum `{ Idle, Working, Blocked, Unknown }` that Ziki's state maps onto.
- **Pane Report**: the structured push (`pane_id`, `source`, `agent`, `state`, `message?`, `seq?`, `agent_session_id?`, `agent_session_path?`) sent to Herdr's `pane report agent` API.
- **Detection Manifest (`ziki.toml`)**: Herdr-side `[[rules]]` mapping Ziki's screen/OSC markers to `AgentState`. This is the contract partner that lives in the Herdr fork (see Dependencies).
- **Goal Session**: Ziki's active goal identity (`agent_session_id` / `agent_session_path`) reported so Herdr can associate state with a specific goal run.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Herdr reports the correct Ziki pane state (`working` / `blocked` / `idle`) within 2 seconds of a state transition, verified via `herdr agent read <pane> --source detection --format json` and `herdr agent explain <pane> --json`.
- **SC-002**: Forklift can distinguish a `blocked` Ziki pane (awaiting input) from a `working` pane and from an `idle` pane with 100% accuracy in a controlled scenario (no transcript scraping).
- **SC-003**: When a Ziki process is killed, Herdr transitions the pane to `unknown` within its detection window and never remains stuck on `working`.
- **SC-004**: With the push path disabled, Herdr still classifies the pane correctly from screen markers and OSC title (`working` / `blocked` / `idle`) via the `ziki.toml` manifest.
- **SC-005**: Ziki's existing goal-execution behavior is unchanged and its test suite remains green (no regression from adding state publication).
- **SC-006**: Every state transition carries a strictly increasing `seq`, and out-of-order pushes never cause Herdr to show a stale state.

## Dependencies / Contract Partner (cross-repo)

This spec lives in the Ziki repo, but detection cannot succeed until the Herdr fork
adds Ziki as a first-class agent. The required Herdr-side changes (tracked
separately in `Developer/herdr`) are:

- Add an `Agent::Ziki` variant (with `agent_label("ziki")` and `parse_agent_label`
  recognition, and inclusion in the screen-manifest agent set) so Ziki panes are
  recognized by process name instead of `unknown`.
- Add a bundled detection manifest `src/detect/manifests/ziki.toml` whose `[[rules]]`
  match Ziki's FR-003 / FR-004 markers to `working` / `blocked` / `idle`.
- Grant `herdr:ziki` lifecycle-report authority (mirroring `herdr:kimi` /
  `herdr:kilo`) so the pane-report push is trusted as the authoritative state.
- Keep the existing `pane report agent` API and the `herdr agent read` / `herdr agent
  explain` query surface as the integration boundary.

Until those land, Ziki's publication (FR-001…FR-008) is complete and testable
against the API, but end-to-end detection in a live Herdr requires the Herdr-side
manifest + agent variant.

## Assumptions

- The integration surface is Herdr's already-shipped `pane report agent` API and its
  detection JSON/CLI (`herdr agent read --source detection`, `herdr agent explain
  --json`); Ziki speaks to that surface and does not invent a new protocol.
- Forklift launches Ziki inside a Herdr pane and Herdr sets `HERDR_PANE_ID` for that
  pane (consistent with Herdr's pane-report tooling), which Ziki reads per FR-008.
- Ziki runs one goal per process/session, so exactly one `AgentState` per pane.
- The installed `kimi-code` integration in Herdr (Speckit skills under `.kimi-code`)
  is unrelated to agent-state detection; Ziki's detection is independent of it.
- Only localhost/loopback Herdr instances are in scope for v1; remote Herdr is not
  excluded by design but is not separately tested.
- State publication adds no network calls to model providers and does not change
  Ziki's goal-execution logic (per the project constitution's Open/Closed and
  Interface-Segregation principles — new state-publishing code is added behind the
  existing composition root, not patched into the executor).
