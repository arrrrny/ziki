# TDD Verification: Herdr ↔ Ziki Agent-State Integration

**Feature**: `specs/011-herdr-ziki-state-sync`
**Profile**: `.specify/memory/tdd-profile.md` (zig, `single`/`file` unavailable → full suite only)
**Commit**: `9376b03` (worktree branch `011-herdr-ziki-state-sync`)
**Date**: 2026-08-27

## Verdict: PASS_WITH_GAPS

The feature is delivered test-first with a green suite and 100% coverage of all
**production** code added for this feature. The only uncovered lines are (a) one
env-gated test-guard line in `herdr.zig` and (b) pre-existing `executor.zig` lines
that predate this feature. Neither is a feature defect, so no remediation is
required to ship.

## Evidence

### 1. Test-first discipline
- `tdd/test-list.md`: all 24 behaviors (`A1`–`A5`, `U1`–`U19`) marked `DONE`, each
  with a concrete `test` reference to the exact file:line it is exercised by.
- `tdd/cycle-log.md`: baseline (40 passed) + final reconciliation entry (65 → 66
  passed) recording the production-build fix.
- `tasks.md`: 30/30 tasks ticked `[x]`. Setup (T001), foundational (T002–T006),
  story tasks (T007–T030), docs (T019 quickstart, T020 README), and the final
  green-gate (T021) are all complete.

### 2. Suite (authoritative: `zig test tests.zig` / `zig build test`)
- **66 passed, 0 failed.** (40 baseline + 25 herdr/state-sync + 1 added transport-
  error test.) Re-run after every change this session.
- **Production build**: `zig build` → 0 errors; `zig-out/bin/ziki` compiles and runs
  (`/goal --help` works). The one build break found this session — an invalid
  `try std.process.getEnvVarOwned(...) catch null` on `HERDR_PANE_ID` in `main.zig`
  (the API returns `[]u8`, not an error union, in Zig 0.15.2) — was fixed to
  `std.posix.getenv("HERDR_PANE_ID")` and re-verified green.

### 3. Coverage (kcov, `kcov --include-pattern=src/`)
| Module | Coverage | Notes |
| --- | --- | --- |
| `src/agent/state.zig` | **100.00%** (183/183) | `AgentState`, `StatePublisher`, `FakeHerdrReporter` |
| `src/main.zig` | **100.00%** (27/27) | `buildStatePublisher` pane-id boundary |
| `src/agent/herdr.zig` | 95.65% (88/92) | sole gap = L189, an env-gated test guard (see Gaps) |
| `src/agent/executor.zig` | 91.18% (341/374) | pre-existing; new publisher wiring covered by U14–U18 |
| **Total `src/`** | **95.66%** | up from 86.92% baseline |

### 4. Mutation (deliberate mutant — no Zig mutation tool exists)
- Mutant: `self.seq += 1` → `self.seq += 0` in `StatePublisher.publish`
  (`src/agent/state.zig:97`).
- Result: **3 tests failed** — `U4` (`StatePublisher seq is strictly increasing`)
  and `A5` (`seq is strictly increasing across rapid transitions`) plus the
  transition test at `state_sync_test.zig:382`. The invariant is defended.
- Mutant restored exactly; suite returned to 66 passed.

### 5. Acceptance-criteria coverage
All 8 functional requirements are traced to behaviors, and all 6 success criteria
are exercised:
- FR-001/FR-002/FR-005/FR-007 → U1, U3, U10, A1. FR-003/FR-004 → U5, U6, U7, A4.
- FR-006 → U15, U16, A3. FR-008 (degrade + error isolation) → U8, U9, U11 error
  path, A4, U19. FR-002 contract §2 → U11 (exact JSON body + endpoint).
- SC-001/SC-002/SC-004/SC-005/SC-006 → A1–A5, U18 (backward-compat: executor
  runs unchanged with `publisher = null`).

**Out of scope (cross-repo, no Ziki test possible)**: US1-4 / SC-003 (pane death →
`unknown` resolved by Herdr's detection window) and US4-1/US4-2 (sidebar badges —
Herdr-side `Agent::Ziki` variant + `ziki.toml` manifest). Recorded in
`test-list.md` Out of scope and in `contracts/herdr-agent-state.md`.

## Gaps (non-blocking)
1. **`herdr.zig:189` (1 line, 95.65% raw)** — a test guard that frees a pre-existing
   `HERDR_API_URL` only when that variable is externally set. It is test-harness
   code, not production logic; the production path (env unset → default) is covered.
   Reaching 100% would require mutating process environment at runtime, which the
   profile forbids (no `setEnvVar`/`unsetEnvVar` in Zig 0.15.2 `std.process`).
   Acceptable as-is.
2. **`executor.zig` 91.18%** — pre-existing lines unrelated to this feature (goal
   loop, git porcelain parsing, report). Not in scope for 011.

## Smells
- None introduced. `FakeHerdrReporter` / `CapturingTransport` mirror the existing
  `FakeProvider` DI pattern; the push path is best-effort and error-swallowing
  (U9, U11 error path), so a Herdr outage never breaks a goal turn.
- Dependency inversion preserved: `GoalExecutor` takes an optional
  `?StatePublisher`; no new global state; session id/path flow from the `Goal`.

## Remediation
No remediation tasks required. The feature is complete, green, and ships as-is.
