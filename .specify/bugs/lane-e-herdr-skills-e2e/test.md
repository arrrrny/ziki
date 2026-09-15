# Bug Test: [Lane E] Herdr/skills e2e + spec 012 + two confirmed bugs

- **Slug**: lane-e-herdr-skills-e2e
- **Tested**: 2026-09-15
- **Fix report**: ./fix.md
- **TDD audit**: ./tdd/verification.md (verdict: PASS_WITH_GAPS)
- **Result**: **verified**

## Reproduction re-run

1. **Herdr use-after-free**: the regression test
   (`HerdrHttpClient outlives the caller's api_url`) reproduces the original crash
   scenario on demand — caller frees `api_url` right after `init`, then the client
   reports. With the fix reverted (mutant M1) the suite crashes (bus error / signal 6);
   with the fix it passes cleanly under `std.testing.allocator`. → **resolved**
2. **SESSION_ID "default"**: with resolution pinned back to `"default"` (mutant M2),
   U1 (precedence) and A2 (repository isolation: `goal.pane-1.json` vs
   `goal.pane-2.json`, no shared `goal.default.json`) both fail. With the fix they pass;
   `ZIKI_SESSION_ID`/`HERDR_PANE_ID` now isolate side-by-side windows. → **resolved**

## Regression / suite runs

- `zig build test` (Zig 0.15.2, CI gate toolchain): **123 passed, 1 skipped** — the
  skip is the network-gated live-provider test (`ZIKI_API_KEY` unset), which skips by
  design in CI.
- Full suite includes the issue's feature work: skill e2e goal test (A3) and the spec
  012 socket transport tests (U2/U3/U4/A4, real Unix-socket round-trip).
- Mutation strength: 3/3 deliberate mutants killed (see [tdd/cycle-log.md](tdd/cycle-log.md)).

## Checklist against the issue

- [x] Bug: Herdr use-after-free — dupe in `init`, free in `deinit`, regression test survives `std.testing.allocator`
- [x] Bug: `SESSION_ID` — derived from `ZIKI_SESSION_ID` → `HERDR_PANE_ID`, defaults to `"default"`; repository isolation tested
- [x] Feature: skill-driven end-to-end goal test (FakeProvider scripting + FakeFs + tmpDir on-disk skill root)
- [x] Feature: spec 012 local-socket transport — spec draft ported from `origin/012-socket-connection`, `SocketTransport` behind the existing `Transport` interface + tests
- [x] Acceptance: `zig build test` green; each bug fix carries a regression test

## Notes

- `zig` was not installed locally; the suite was executed on the official Zig 0.15.2
  toolchain (identical to the CI gate version) downloaded to `~/sdk`.
- Branch: `fix/lane-e-herdr-skills-e2e` (issue suggested `017-herdr-skills-e2e`; the
  bug workflow's `fix/<slug>` convention was used).
