# TDD Cycle Log — lane-e-herdr-skills-e2e

## Baseline

- **Commit**: master @ df28833 (pulled latest origin/master before branching)
- **Branch**: `fix/lane-e-herdr-skills-e2e`
- **Suite**: `zig build test` → **GREEN** (baseline suite per profile `suite_baseline: green`)
- **Behaviors**: 4 acceptance + 4 unit, all PENDING

## Cycle 1 — A1 (bug 1: Herdr use-after-free)

- **RED**: added `HerdrHttpClient outlives the caller's api_url (use-after-free regression)`
  (+ converted the three existing client tests to the ownership contract). Suite:
  compile errors — `expected error union type, found HerdrHttpClient` at
  `src/agent/herdr.zig:130/159/204/228` (no owning `init`, no `deinit`). Right reason:
  the ownership API does not exist yet.
- **GREEN**: `HerdrHttpClient.init` now dupes `base_url` (returns `!HerdrHttpClient`)
  and `deinit` frees it; `buildStatePublisher` uses `defer` for its copy and
  `runGoal` deinits the client slot. Suite: 117/118 passed, 1 gated skip → green.

## Cycle 2 — U1 + A2 (bug 2: SESSION_ID)

- **RED**: added `resolveSessionIdFrom precedence … (U1)` and
  `resolved session ids isolate goal repositories (A2)`. Suite: compile errors —
  `use of undeclared identifier 'resolveSessionIdFrom'` at `src/main.zig:556/583`.
  Right reason: resolution does not exist; id was the `"default"` constant.
- **GREEN**: replaced `const SESSION_ID = "default"` with `resolveSessionId`
  (`ZIKI_SESSION_ID` → `HERDR_PANE_ID` → `"default"`, empty = unset), threaded the
  resolved id through goal/stop/status/goals; stop-file path built at runtime.
  Suite green.

## Cycle 3 — A3 (feature: skill-driven e2e goal test)

- **TEST-FIRST, ALREADY GREEN (honest note)**: added
  `src/skill/e2e_test.zig` + aggregator import. The test exercises only existing
  production paths (SkillRegistry.load over a real tmpDir via RealFs → listingText →
  GoalExecutor.run with SkillTool/WriteTool). First full-suite run passed with no
  production change needed; no red state existed to record, and none was fabricated.
  Strength proven by mutant M3 below instead. Suite: 118/119 + gated skip.

## Cycle 4 — U2/U3/U4 + A4 (feature: spec 012 socket transport)

- **RED**: added `src/provider/transport_socket.zig` tests; module + wiring absent.
  Suite: compile error — `file not found`/aggregator import of the new module.
  (Also ported the spec 012 draft from `origin/012-socket-connection` onto master:
  `specs/012-socket-connection/{spec.md,checklists/}`.)
- **GREEN**: implemented `Selection`/`selectByUrl`, `splitUnixUrl`, `SocketTransport`
  (per-request `std.net.connectUnixSocket`, HTTP/1.1 wire shape, close-delimited
  response parse), and selection in `buildStatePublisher` (`unix://` → socket
  transport in `herdr_socket_slot`; http(s) unchanged; unsupported scheme → clear
  error + fail fast). One test-data fix during the cycle: Content-Length 9 → 11 for
  `{"ok":true}` (test bug, not product). Suite: 123/124 + gated skip → green.

## Final suite state

- `zig build test` → **GREEN**: 123 passed, 1 skipped (network-gated live-provider
  test; skips without `ZIKI_API_KEY` by design). Runs with `env -u ZIKI_API_KEY`
  to match CI parity on this machine.

## Mutation checks (profile `mutation: null` → deliberate mutants)

| # | Mutant | Result |
|---|--------|--------|
| M1 | `HerdrHttpClient.init` stores `base_url` by reference (ownership removed) | **KILLED** — suite crashes (bus error / signal 6) in the herdr client tests |
| M2 | `resolveSessionIdFrom` always returns `"default"` | **KILLED** — U1 precedence + A2 isolation both fail |
| M3 | `SkillTool.execute` returns an empty body | **KILLED** — SkillTool verbatim-body test + skill e2e (A3) both fail |

All mutants reverted exactly; final suite re-run green after reversion.
