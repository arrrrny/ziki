# TDD Verification — 013-goal-loop-hardening

**standard**: `.specify/extensions/tdd/templates/tdd-test-quality-rubric.md` (resolved via the extension's own copy; no overrides/presets present)
**profile**: `.specify/memory/tdd-profile.md` | **feature**: `specs/013-goal-loop-hardening/` (resolved via `check-prerequisites.sh` from `.specify/feature.json`)
**verified_at**: f4648e2 (code) + pending cycle-D commit (artifacts) | **suite**: `zig build test`
**disclosure**: the audit was performed by the same session that wrote the tests — NOT independent. Cold reads of every assessed file were done, and the deliberate mutants (Phase 4) were executed fresh against the tree, but the smell pass carries the inherent bias of authorship.

## Verdict: PASS_WITH_GAPS

The discipline held (test-first per cycle, recorded reds, no weakened pre-existing tests, three-of-three deliberate mutants killed by the new tests). Gaps: authorship non-independence, mutation score unmeasured by tooling (none exists for Zig — deliberate mutants used instead), timing-dependent abort tests, and one tautological sanity assertion.

## Phase 0 — Preflight

- Suite: `zig build test` → **135 passed, 1 skipped** (the skip is the pre-existing live-provider e2e test, excluded by design), wall 4.8 s warm / ~41 s cold (profile baseline 41 s — matches).
- Baseline: profile records `suite_baseline: green` pre-feature; the only failures observed during the feature were the recorded cycle reds and the three deliberate mutants.
- `kcov` not installed on this host → coverage **unmeasured** for this audit (profile's 86.92% baseline predates the feature).

## Phase 2 — Test-first evidence

| Behavior | Classification | Evidence |
|---|---|---|
| B1 history round-trip | PROVEN | test in cycle-A commit (d2e56d6) alongside impl; compile-red recorded before vtable/history fns existed |
| B2 foreign goal_id rejected | PROVEN (mutant-verified) | cycle A; M3 (guard removed) → B2 fails |
| B3 missing/corrupt history | PROVEN | cycle A |
| B4 clear_history | PROVEN | cycle A |
| B5 transcript persisted per turn | PROVEN | cycle D commit (B18 asserts the stored shape end-to-end) |
| B6 seeded history sent verbatim | PROVEN | cycle D; RecordingProvider asserts request contents |
| B7/B8 compaction + accounting | PROVEN (mutant-verified) | cycle B; M1 (compact always false) → B7 fails |
| B9 token budget graceful stop | PROVEN | cycle B; persisted-status + progress string asserted |
| B10 reported vs estimated usage | PROVEN | cycle B; both paths asserted on `used.tokens` |
| B11 time budget stop | PROVEN | cycle B; zero provider calls asserted |
| B12 no dispatch after signal | PROVEN (mutant-verified) | cycle C; M2 (probe blind) → B12 fails |
| B13 late response discarded | PROVEN (mutant-verified) | cycle C; M2 → B13 fails |
| B14 Bash mid-command kill | LIKELY | probe check sits in the poll loop before the timeout check; asserted indirectly via the executor-level shared-probe tests (B15) and the real-binary SIGTERM run; no direct bash-only probe test |
| B15 aborted Bash result → goal abort | PROVEN | DelayedProbe shared by executor+Bash; abort + persisted status asserted |
| B16 retry stops after signal | PROVEN (mutant-verified) | M2 → B16 fails (1 call, aborted) |
| B17 resume guards | PROVEN | pure `resumeGuard` classification test (main.zig) + real-binary guard runs (empty store / wrong id / terminal) |
| B18 resume round-trip | PROVEN | cycle D; two-executor run through FsGoalRepository on FakeFs; carried counters + replayed transcript + terminal history clear asserted |
| B19 usage parse/null | PROVEN | cycle A (openai.zig tests) |
| B20 pre-existing suite stays green | PROVEN | 135/135 across all cycles; diff shows zero removed/loosened assertions in pre-existing tests (bash `runWithTimeout` call-site signature updates only; executor/bash test bodies untouched) |

**Existing-test weakening**: none found (`git diff 22e23da..HEAD -- src/tool/bash.zig src/agent/executor.zig` — no removed `test "` blocks, no loosened assertions).

**tasks.md ↔ test-list consistency**: all behavior rows `done` ↔ all behavioral tasks T1–T14 ticked with commits as evidence — consistent.

## Phase 3 — Smell pass (author-biased; see disclosure)

- **Tautological sanity assert (LOW)** — `executor.zig` B7: `expectEqualStrings("done", responses[2].message.content)` asserts the script constant, not behavior. Should assert the *request shape* instead (e.g. via a RecordingProvider that the compacted request was smaller). The behavioral assertions in the same test (compactions==1, `used.tokens < 81`, report line) carry it; still, the line should be replaced.
- **Timing dependence (MEDIUM)** — B13 (provider sleeps 150 ms vs 50 ms poll) and B15 (`DelayedProbe` 200 ms vs Bash poll 200 ms) rely on timing slop. Deterministic on any realistic host (ratios ≥ 3×) but not free of scheduler risk. A clock-injectable probe would remove it.
- **Indirect assertion (LOW)** — B12's `fp.idx == 1` infers "one turn only" from FakeProvider's internal index rather than counting provider calls directly.
- **Isolation/determinism/speed** — good: all doubles are the profile's fakes (FakeFs/FakeProvider/RecordingProvider), no network, full suite ~5 s warm. New fakes (AtomicProbe/DelayedProbe/RaiseProbeTool) follow the hand-written-DI convention of the exemplars.
- **Foreign style / bypassed helpers / framework-under-test** — none found; new tests use `std.testing`, FakeFs, and live in the same file as the code per profile conventions.
- **stdout discipline** — one incident recorded (cycle log): a test invoking `runResume` emitted to stdout and hung the build-runner protocol; removed, and the invariant is now documented in main.zig's test comment.

## Phase 4 — Test strength (deliberate mutants; no Zig mutation tool exists)

| Mutant | Change | Observed | Killed by | Restored |
|---|---|---|---|---|
| M1 | `compact()` returns false unconditionally | suite RED | B7 (`1 failed`: compaction test) | ✓ suite green 135/135 |
| M2 | `stopRequested()` returns false unconditionally | suite RED | B12 + B13 + B16 (`3 failed`) | ✓ |
| M3 | history `goal_id` guard removed (`_ = goal_id`) | suite RED | B2 (`1 failed`) | ✓ |

Every survivor-free result maps to the behavior that claims the coverage — no surviving mutants to triage. Equivalent-mutant candidates (progress strings, verbose lines) not mutated: log-only.

**Mutation scope note**: mutants cover the three hard edges (compaction, abort observation, history scoping). Not mutated: `estimateTokens` arithmetic, `--timeout` flag wiring in main.zig (CLI parse is untested at unit level — see gaps).

## Gaps → remediation (appended to tasks.md)

1. **G1 (MEDIUM)**: B14 lacks a direct BashTool probe test (probe checked in `runWithTimeout` poll loop, kill path, `aborted` flag). Add `test "BashTool stop probe terminates a hanging command"`.
2. **G2 (LOW)**: replace the B7 tautological sanity assert with a request-shape assertion (RecordingProvider message count before/after compaction).
3. **G3 (MEDIUM)**: CLI flag wiring (`--max-tokens/--max-turns/--timeout` → `budgets`) has no unit test; main.zig arg parsing is untestable as written (emits to stdout). Extract a pure arg-parsing fn.
4. **G4 (LOW)**: clock-injectable `StopProbe` to de-time B13/B15.
5. **G5 (INFO)**: coverage unmeasured on this host (no kcov); rerun the profile's kcov command where available to compare against the 86.92% baseline.
