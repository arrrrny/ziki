# Tasks: [Lane A] Goal loop hardening: resume, budgets, compaction, abort

**Branch**: `013-goal-loop` | **Spec**: `spec.md` | **Plan**: `plan.md`

## Phase 1 — Data layer (M1)

- [ ] **T1** `provider.zig`: add `TokenUsage { prompt_tokens: u64, completion_tokens: u64 }` and `ChatResponse.usage: ?TokenUsage = null`; `fake.zig` clone carries it. (US2)
- [ ] **T2** `openai.zig`: parse top-level `usage.prompt_tokens`/`usage.completion_tokens` into `resp.usage` when present (tolerant of omission). (US2)
- [ ] **T3** `repository.zig`: history persistence — vtable `save_history(goal_id, messages)` / `load_history(goal_id) → ?[]ChatMessage` / `clear_history()`; file `<dir>/history.<session>.json` (`{"goal_id","messages"}`); corrupt/missing → null; goal_id mismatch → null. (US1)

## Phase 2 — Budgets + compaction in the executor (M2)

- [ ] **T4** Executor token accounting: per-turn usage (reported or estimated from conversation bytes/4) added to `goal.used.tokens`; persisted with the usual per-turn `repo.save`. (US2)
- [ ] **T5** Compaction: when `used.tokens ≥ max_tokens` and middle messages exist, rebuild the conversation in a fresh arena retaining system prompt + original goal message + last `retain_recent` (8) messages + compaction notice; subtract dropped tokens; job-report line "context compacted". (US2)
- [ ] **T6** Token budget stop: exceedance after compaction (or nothing trimmable) → `aborted`, progress "aborted: token budget exceeded", persisted, no further calls. (US2, SC-002)
- [ ] **T7** Time budget: track `used.seconds` (carried persisted seconds + this-run elapsed), check at top of each turn; exceedance → "aborted: time budget exceeded", persisted. Wire `--timeout`/`--no-timeout` (+ new `--max-tokens`/`--max-turns`) from `/goal` into `budgets`. (US3, SC-002)

## Phase 3 — Mid-turn abort (M3)

- [ ] **T8** `StopProbe` seam: `struct { ctx, check }`; executor default = stop-file probe; check before each tool dispatch and right after each provider completion (abort wins: discard response, no message appended, no tool executed). (US4, SC-004)
- [ ] **T9** Provider I/O interrupt: `completeInterruptible` — worker thread on a dedicated page_allocator arena, 50 ms probe polling, abandon+discard on stop, probe-checked retry sleeps/backoff. (US4, SC-004)
- [ ] **T10** Bash tool abort: optional `stop` probe checked in the 200 ms poll loop → SIGTERM child, result "run_command aborted by user", `aborted=true`; executor maps an aborted tool result to goal abort + persisted status. (US4, SC-004)

## Phase 4 — Resume + CLI (M4)

- [ ] **T11** Executor transcript persistence: `repo.saveHistory(goal.id, messages)` at each turn end; executor accepts a seeded history for resume (verbatim replay when present). (US1, SC-001)
- [ ] **T12** `main.zig` resume path: `runResume()` (load goal → FR-002 guards → load history → status active → run); dispatcher `"resume"`; bare `ziki resume [goal-id]` accepted at argv level; `runGoal` clears stale history at start; help/usage text updated. (US1, SC-001)
- [ ] **T13** Signal handling: SIGINT/SIGTERM handlers around goal runs write the stop file (async-signal-safe `write`), restored after the run. (US4)
- [ ] **T14** Full verification: `zig build test` green on 0.15.2; no pre-existing test regressed; TDD verification evidence recorded. (SC-005)

## Dependencies

- T4–T7 depend on T1 (usage field); T11/T12 depend on T3 (history); T9/T10 depend on T8 (probe seam); T7 independent of T1 (pure wall clock).
- Phase order is MVP-first: data layer → loop hard edges → abort → user-facing resume.
- Lane coordination: T12/T13 touch `src/main.zig` (goal path only, tool wiring verbatim) — coordinate with Lane C; out of scope: tool error propagation, push gate.
