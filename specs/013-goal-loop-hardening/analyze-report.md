# Analyze Report: 013-goal-loop-hardening

**Artifacts**: `spec.md` · `plan.md` · `tasks.md` · `tdd/test-list.md` · issue #16 · spec 005 · spec 006

## Consistency Matrix

| Acceptance criterion (issue #16 / spec SC) | Plan decision | Tasks | Test-list behaviors |
|---|---|---|---|
| Resume round-trip: `ziki resume [goal-id]` loads turns from store | D1 (transcript persistence, verbatim replay) + D6 (CLI wiring) | T3, T11, T12 | B1–B6 |
| Budget exhaustion → graceful stop (token + time) | D3 (uniform `aborted` stop shape) + D4 (wall clock) | T4, T6, T7 | B7–B11 |
| Mid-turn abort: `/stop` interrupts provider I/O and Bash tool | D5 (StopProbe + poll loops + abandon-and-discard) | T8, T9, T10, T13 | B12–B17 |
| Context compaction when token budget exceeded | D3 (retain window, arena reset) | T5 | B8, B9 |
| `zig build test` green (CI gate 0.15.2) | — | T14 | B18 |

## Checks Performed

1. **Coverage**: every issue #16 task maps to ≥1 task and ≥1 test-list behavior — no orphan criteria. Spec 005 FR-008/SC-004 (resume without re-definition) covered by T3+T11+T12; spec 006 FR-006 (all three budgets) covered by T4–T7; spec 006 FR-007 (abort wins, no work after signal) covered by T8–T10.
2. **Status semantics**: issue asks for "graceful stop"; existing turn-budget stop uses `.aborted`. Decision recorded in plan D3: token/time exhaustion also stop as `.aborted` with distinct progress strings — uniform with the existing loop, consistent with spec 006's "budget-exceeded maps to a defined stopped status (blocked or aborted)".
3. **Scope guard (hard constraints)**: no changes to the tool registry, no agent-executor error-propagation changes, no push-gate changes. `openai.zig` change is additive parsing (`usage`), not error propagation. Confirmed out of scope in spec.md.
4. **Terminology drift**: spec says "conversation transcript", plan D1 says "transcript", tasks say "history" (file name `history.<session>.json`) — aligned; one term (history) used for the stored artifact, transcript for the concept. No drift remains.
5. **Priority ordering**: P1 stories (resume, token budget+compaction) land in Phases 1–2/4; P2 (time budget, abort) in Phases 2–3. MVP-first: data layer precedes loop changes precedes CLI. Dependency order is acyclic.
6. **Lane conflicts**: tasks touching `src/main.zig` (T12, T13) keep tool wiring verbatim and isolate resume into new functions — matches the issue's coordination note with Lane C.

## Findings (fixed during planning)

- **F1**: Spec scenario 5 (stale-history clearing on fresh `/goal`) had no task → added to T12 (`runGoal` clears history at start) and behavior B6.
- **F2**: Estimated-usage fallback for providers without `usage` was implicit in the spec ("estimated otherwise") but had no task → explicit in T4 and behavior B10.
- **F3**: `--timeout` currently only sets the Bash per-command timeout; the goal time budget needs it wired (FR-010) → explicit in T7; `--max-tokens`/`--max-turns` added so budgets are reachable from the CLI.

## Verdict

No blocking drift. Artifacts are consistent and traceable; proceed to `/speckit.tdd.plan`.
