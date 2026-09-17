# TDD Cycle Log — 014-provider-depth

## Baseline
- **Commit**: master @ bb7d6c2 · **Branch**: `014-provider-depth`
- **Suite**: GREEN (152 passed, 1 gated skip) · **Behaviors**: 4 acceptance + 1 unit, all PENDING

## Cycle 1 — A1/A2/A3/A4 (all behaviors)

- **RED** (infrastructure present, old behavior retained): openai A3 failed
  (`expected error.Unauthorized, found error.ProviderError`), openai A4 (same shape),
  executor A2 (no finish_reason notes in report), executor A3/A4 (error propagated raw
  out of `completeInterruptible` instead of blocked status). A1 (request-shape pinning)
  passed on arrival — characterization test over the existing request builder, recorded
  honestly; response fixtures still caught real gaps (two fixture JSON defects fixed
  during the cycle).
- **GREEN**: status mapping (401→`Unauthorized`, 403→`Forbidden`, 400/404→`ModelNotFound`
  + models probe), `Provider.error_hint` vtable method, fail-fast in the retry loop,
  `finishProviderBlocked` → blocked status with actionable text, finish-reason notes in
  the job report. Suite: 151 passed, 1 gated skip, no leaks → green.

## Test-harness notes (recorded honestly)

- Two of my own test iterations crashed/hung before this clean red: a use-after-free in
  the A1 test (tool_calls freed before asserting) and stale arena slices in an earlier
  A3 sketch. Both were test bugs; sampling the hung runner showed
  `handleSegfaultPosix → Progress.global_progress` (Zig 0.15 runner deadlock on
  segfault). No production code involved.
- Fixture defects (missing comma / stray brace / doubled backslashes) were caught by
  the suite and fixed — fixtures validated against a JSON parser afterward.

## Mutation checks

| # | Mutant | Result |
|---|--------|--------|
| M1 | 401 mapped to `ProviderError` (generic) | **KILLED** — openai A3 fails |

Reverted exactly; final suite green (151 passed, 1 gated skip, no leaks).
