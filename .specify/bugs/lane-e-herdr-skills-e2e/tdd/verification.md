# TDD Verification — lane-e-herdr-skills-e2e

- **Audited**: 2026-09-15 (cold-context audit per `/speckit.tdd.verify`)
- **Feature dir**: `.specify/bugs/lane-e-herdr-skills-e2e`
- **Suite**: `zig build test` (Zig 0.15.2) → **GREEN**: 123 passed, 1 skipped (network-gated
  live-provider test; skips without `ZIKI_API_KEY` — documented gate, not a gap)
- **Artifacts audited**: [test-list.md](test-list.md) · [cycle-log.md](cycle-log.md) · [../fix.md](../fix.md)

## Verdict: **PASS_WITH_GAPS**

All 8 behaviors (4 acceptance + 4 unit) are DONE with red→green evidence; the two bug
regressions and the skill e2e are mutation-proven. The gaps below are environmental /
contractual, none blocking.

## Test-first evidence

| Behavior | Red evidence | Green evidence |
|----------|--------------|----------------|
| A1 use-after-free regression | compile errors: `init` not an error union, no `deinit` (herdr.zig:130/159/204/228) | suite green; caller-free-then-report survives `std.testing.allocator` |
| U1 session precedence | compile error: undeclared `resolveSessionIdFrom` (main.zig:556/583) | suite green |
| A2 repository isolation | same red as U1 | suite green (per-session state files asserted) |
| A3 skill e2e | **none — honest gap**: test exercised only existing production paths and passed first run; no red was fabricated | suite green; strength proven by mutant M3 |
| U2/U3/U4 + A4 socket | compile error: new module not implemented | suite green incl. real-Unix-socket round-trip |

## Test strength (mutation checks — profile `mutation: null` → deliberate mutants)

- **M1** ownership removal in `HerdrHttpClient.init` → **KILLED** (suite crashes in herdr client tests).
- **M2** `resolveSessionIdFrom` pinned to `"default"` → **KILLED** (U1 + A2 fail).
- **M3** `SkillTool.execute` returns empty body → **KILLED** (SkillTool verbatim + A3 e2e fail).
- All reverted exactly; final suite re-run green after reversion.

## Smells reviewed

- No test sleeps/retries; the socket round-trip uses blocking accept/read (same
  pattern as the existing proxy test in `transport.zig`), deterministic on localhost.
- No production logging of test state; fakes (`FakeFs`, scripted providers,
  fixed-buffer writers) only — no `std.fs`/network in tests except the two
  intentionally-real loopback/socket listeners, which mirror the established
  transport-test convention.
- Memory: all new paths clean under `std.testing.allocator` (suite runs leak detection;
  `herdr_client_slot`/`herdr_socket_slot` lifetimes covered by run-scoped `defer`s).

## Acceptance-criteria coverage

- Issue acceptance "`zig build test` green; bug fixes each carry a regression test" — met (A1, A2).
- Spec 012 FR-002/FR-004/FR-005/FR-006/FR-007 covered (U2..U4, A4; HTTP transport untouched; zero new deps).
- Spec 012 SC-005 (all selection cases tested) — met. SC-001/SC-002 delivery
  equivalence — request shape asserted by the listener (A4); full end-to-end against a
  real Herdr socket listener is out of scope for the offline suite (see Gaps).

## Gaps (non-blocking)

1. **A3 had no red phase** (behavior already implemented; test pins the wiring).
   Compensated by mutant M3.
2. **No coverage run this cycle**: kcov requires the cached test binary hash and was
   skipped; delta limited to touched files, all of which are directly asserted.
3. **Live Herdr socket listener** not exercised (external system; profile `acceptance: null`).
4. `HERDR_API_URL=unix://…` selection inside `buildStatePublisher` is covered via the
   pure classifiers (`selectByUrl`/`splitUnixUrl`), not an env-dependent integration
   test (process env cannot be set portably in-process).

## Remediation

None required — no FAIL findings. Gaps recorded for the next audit of this area.
