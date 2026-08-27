# Quickstart: Validate Herdr ↔ Ziki Agent-State Integration

**Feature**: 011-herdr-ziki-state-sync | **Date**: 2026-08-27

How to prove the feature works end-to-end. The Ziki-side unit/integration tests
run offline with fakes (see `src/agent/state.zig`, `src/agent/herdr.zig`); the
live cross-repo checks require the Herdr-side manifest (partner work).

## 1. Run the test suite (offline, authoritative for CI)

From the repo root:

```bash
zig build test          # equivalent: zig test tests.zig
```

All tests must pass, including the new `src/agent/state.zig` and
`src/agent/herdr.zig` suites:
- `AgentState` mapping to Herdr states (FR-005)
- `StatePublisher.publish` pushes correct `PaneReportParams` with monotonic `seq` (FR-002, SC-006)
- screen marker + OSC emission on every publish (FR-003, FR-004)
- degrade-to-screen-only when `HERDR_PANE_ID` absent; swallow reporter errors (FR-008, T7)
- `GoalExecutor` publishes `working` at start and the correct terminal state (FR-001, T1–T4) without changing its logic (SC-005)

Coverage (optional, kcov installed):
```bash
kcov --include-pattern=src/ kcov-out .zig-cache/o/<hash>/test
```

## 2. Live push against a local Herdr (requires Herdr-side manifest)

Prereqs: a Herdr instance on `localhost:7878` with `Agent::Ziki` + `ziki.toml`
(after the cross-repo partner work lands), and a pane id.

```bash
export HERDR_PANE_ID="pane-abc"
export HERDR_API_URL="http://localhost:7878"
# Run a short Ziki goal
ziki /goal "create a file hello.txt containing hi" --no-clean
# In another shell, read the pane state
herdr agent explain pane-abc --json
```

Expected:
- During execution: `working`.
- On completion: `idle`.
- If a criterion is given and cannot be satisfied: `blocked`.

## 3. Degraded (screen/OSC only) check

Run Ziki **without** `HERDR_PANE_ID` set; confirm it still emits the
`[ziki-state: <state>]` markers and OSC title to its stdout and does not crash
(SC-004 fallback path, FR-008).

## 4. Contract conformance checklist

- [ ] Push body matches `contracts/herdr-agent-state.md` §2 (exact field names, `source="herdr:ziki"`, `agent="ziki"`).
- [ ] Screen marker matches §3; OSC title matches §4.
- [ ] `seq` strictly increases across publishes.
- [ ] Absent `HERDR_PANE_ID` → no push attempt, no crash.
