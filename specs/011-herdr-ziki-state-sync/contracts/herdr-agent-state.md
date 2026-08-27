# Contract: Ziki ↔ Herdr Agent-State Integration

**Feature**: 011-herdr-ziki-state-sync | **Date**: 2026-08-27

This is the integration boundary Ziki speaks to. It is the single contract seam
between the two repos. The Herdr-side additions (`Agent::Ziki`, `ziki.toml`
manifest, `herdr:ziki` authority) are the contract *partner* and live in
`Developer/herdr`; this file pins what Ziki MUST produce.

## 1. Environment variables (Ziki reads these)

| Variable | Required | Default | Purpose |
|---|---|---|---|
| `HERDR_PANE_ID` | no | — | The pane id Herdr assigned to this Ziki process. Absent → screen/OSC-only mode (FR-008). |
| `HERDR_API_URL` | no | `http://localhost:7878` | Base URL of Herdr's API server for the `pane report agent` push. |

## 2. Push API (authoritative path — FR-002)

- **Method**: `POST`
- **URL**: `${HERDR_API_URL}/api/v1/pane/report/agent`
- **Headers**: `Content-Type: application/json`
- **Body**: JSON `PaneReportParams` (schema below)

```json
{
  "pane_id": "pane-XYZ",
  "source": "herdr:ziki",
  "agent": "ziki",
  "state": "working",
  "message": "optional human-readable context",
  "seq": 3,
  "agent_session_id": "goal-<nanots>",
  "agent_session_path": "/abs/path/to/.ziki"
}
```

| Field | Constraint |
|---|---|
| `pane_id` | non-empty string (from `HERDR_PANE_ID`) |
| `source` | MUST be exactly `"herdr:ziki"` |
| `agent` | MUST be exactly `"ziki"` |
| `state` | one of `"idle"` / `"working"` / `"blocked"` (lower-cased Ziki `AgentState`) |
| `message` | optional; present when blocked/aborted |
| `seq` | strictly increasing unsigned integer across the process lifetime |
| `agent_session_id` | optional; `goal.id` |
| `agent_session_path` | optional; process `state_dir` |

Herdr trusts this report for lifecycle state because `source` carries
`herdr:ziki` authority (mirroring `herdr:kimi` / `herdr:kilo`).

## 3. Screen marker (fallback — FR-003)

Emitted on stdout on its own line, on every `publish`:

```
[ziki-state: <state>]            # e.g. [ziki-state: working]
[ziki-state: <state>] <message>  # e.g. [ziki-state: blocked] criterion not satisfied after retries
```

- Plain ASCII, no ANSI codes, so Herdr's `ziki.toml` manifest can match it via
  `contains` / `line_regex` in the `bottom_lines(N)` / `whole_recent` regions.
- The `<state>` token is one of `idle` / `working` / `blocked`.

## 4. OSC title (fallback — FR-004)

Emitted on stdout (terminal escape sequence) on every `publish`:

```
\x1b]2;ziki:<state>\x07
```

- Read by Herdr's `osc_title` detection region.
- `<state>` is one of `idle` / `working` / `blocked`.

## 5. Query surface (Herdr-side, read-only for Ziki's consumers)

Forklift / humans read Ziki state via Herdr, not Ziki:

- `herdr agent read <pane> --source detection --format json`
- `herdr agent explain <pane> --json`

These are the verification surface for SC-001 / SC-002 / SC-004.

## 6. Out of scope for this contract (cross-repo partner)

Tracked separately in `Developer/herdr`; Ziki cannot test them in this repo:

- Adding `Agent::Ziki` so Ziki panes are recognized by process name (not `unknown`).
- Adding `src/detect/manifests/ziki.toml` whose `[[rules]]` match §3/§4 markers.
- Granting `herdr:ziki` lifecycle-report authority.

Until these land, Ziki's publication (§2/§3/§4) is complete and testable
against the API, but live end-to-end detection in a running Herdr requires the
Herdr-side manifest.
