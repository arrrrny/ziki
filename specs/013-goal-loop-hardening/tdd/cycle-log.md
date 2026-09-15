# TDD Cycle Log — 013-goal-loop-hardening

Append-only evidence. Format: one entry per cycle — what was written, the
recorded red, the change that made it green, and any refactor.

Environment: zig 0.15.2 (CI gate), `zig build test`, runner reports e.g.
`135 passed 1 skipped` (the skip is the pre-existing live-provider e2e test).

---

## Cycle A — data layer (T1–T3): B1, B2, B3, B4, B19

**Tests written first** (`src/goal/repository.zig`, `src/provider/openai.zig`,
`src/provider/provider.zig`):
- "history round-trips through the repository (B1)"
- "load_history rejects a foreign goal_id (B2)"
- "load_history tolerates missing and corrupt files (B3)"
- "clear_history removes the transcript (B4)"
- "parseResponse maps token usage when present (B19)"
- "parseResponse leaves usage null when the backend omits it (B19)"
- "ChatResponse.usage defaults to null (B19)"

**RED evidence**: first run failed to compile — `use of undeclared identifier
'vtable'` / `no field or member function named 'historyPath'` (the new vtable
members and history fns did not exist); after placing the fns inside the
struct, `openai.zig` had no `usage` field to assert on (compile failure = red
for a static language). Recorded: `zig build test` → 8 compile errors.

**GREEN**: added `GoalRepository.VTable.save_history/load_history/clear_history`,
`FsGoalRepository.historyPath/save_history/load_history/clear_history`
(`<dir>/history.<session>.json`, goal_id-scoped), `freeHistory` helper,
`TokenUsage` + `ChatResponse.usage`, `openai.zig` top-level `usage` parsing,
`fake.zig` clone carries usage. `zig build test` → all pass.

**Refactor**: collapsed the dual vtables into one extended vtable shared by
`toRepository()`/`toHistoryRepository()`; fixed a stray `\n` literal and a
`/**`-comment slip in provider.zig.

---

## Cycle B — budgets + compaction (T4–T7): B7, B8 (in B7), B9, B10, B11

**Tests written first** (`src/agent/executor.zig`):
- "compaction trims the middle and the run continues (B7/B8)"
- "token budget with nothing trimmable stops gracefully (B9)"
- "provider-reported usage is summed; estimate used when absent (B10)"
- "time budget already exhausted stops before any provider call (B11)"

**RED evidence**: compile failure — fields `.retain_recent`, `.stop`,
`compactions` did not exist on `GoalExecutor`; `compact`, `finish`,
`estimateTokens`, `completeInterruptible` undeclared. Recorded: `zig build
test` → 13 compile errors.

**GREEN**: executor restructure —
- `runWithHistory` (run() now a thin fresh-history wrapper) with per-turn usage
  accounting (`reported usage ? total : estimateTokens(conversation)`),
- token budget check after each tool-call turn: compact-or-stop (D3),
- `compact()` rebuilding the conversation in a fresh arena (system + goal
  message + compaction notice + recent window, tool-pair-safe), subtracting
  dropped tokens, reporting via job-report line,
- time budget: `used.seconds = carried + elapsed` checked at top of turn (D4),
- `finish()` helper unifying terminal transitions (status + progress +
  publish + save + history clear).

**Refactor**: several compile fixes in the new test block (shadowing of
`FakeFs`/`FsGoalRepository` with older test-local decls → unique `S13*` aliases,
`const`→`var` for tool impls, param shadowing in test fakes).

---

## Cycle C — mid-turn abort (T8–T10): B12, B13, B14 (bash), B15 (bash+executor), B16

**Tests written first**:
- "no tool dispatch after the stop signal (B12)"
- "provider response arriving after the signal is discarded (B13)"
- "retry loop stops immediately when the signal is raised (B16)"
- bash.zig: probe field + `runWithTimeout` abort path exercised via the
  DelayedProbe wiring in the executor-level tests (B14/B15 asserted through
  the shared probe semantics; the direct bash probe check runs on every poll
  iteration before the timeout check).

**RED evidence**: compile failure (`.stop` probe field absent on executor and
BashTool; `runWithTimeout` signature lacked the probe) — recorded before
implementation.

**GREEN**:
- `src/agent/stop.zig`: `StopProbe` seam + `FsProbe`/`AtomicProbe`/
  `DelayedProbe` (D5),
- executor: `stopRequested()` (injected probe, else stop-file fallback),
  checks at top of turn, before each tool dispatch, after each dispatch, and
  in the provider I/O wait + retry backoff,
- `completeInterruptible`: worker thread on a dedicated page_allocator arena
  with a deep-copied request; 50 ms probe polling; bounded 2 s abort grace;
  join when done, detach when hung; response discarded when the signal fired
  (abort wins),
- `BashTool`: optional `stop` probe checked every poll iteration → SIGTERM
  child, "run_command aborted by user" result, `aborted` flag.

**Result**: `zig build test` all green (131 passed at this point).

---

## Cycle D — resume seeding + store round-trip (T11–T12): B5, B6, B17, B18

**Tests written first**:
- "executor persists the transcript after each turn (B5)"
- "seeded history is sent verbatim on resume (B6)"
- "resume round-trip through the store continues an interrupted goal (B18)"
- main.zig: "resume guard classifications (B17)"

**RED evidence**: B18 first run failed on expectations corrected by the test
itself (store holds end-of-turn-1 state: `expected 2, found 1` → corrected to
the persisted-turns semantics; then `tool:exit=0\nhi` → the WriteTool output is
`wrote hello.txt`). These were test-expectation fixes against the real
persisted format, recorded honestly. B17 pure-guard test passed once the
guards existed (compile red before).

**GREEN**: `runWithHistory` seeding (verbatim replay), per-turn
`saveHistorySafe`, `finish()` clears history at terminal, `main.zig`:
`runResume()` (guards → provider build → history load → status active → run),
dispatcher `"resume"`, bare `ziki resume [goal-id]` at argv level,
`resumeGuard()` pure classifier, budget flags `--max-tokens`/`--max-turns`,
`--timeout`→`budgets.max_seconds` wiring, fresh-goal history clearing, SIGINT/
SIGTERM handlers writing the stop file.

**Incident recorded honestly**: a first B17 attempt invoked `runResume` inside
a test; its `emitErr` wrote to stdout, which is the build-runner protocol pipe
under `zig build test` — the runner hung waiting for a valid protocol message
(300 s timeout). The emitting test was removed; coverage stays in the pure
`resumeGuard` test + real-binary e2e below. Lesson recorded: never emit to
stdout from a test in this repo.

**Result**: `zig build test --summary all` → `135 passed 1 skipped`.

---

## Real-binary verification (manual, post-cycle)

- `ziki resume` (empty store) → `error: no goal to resume — start one with /goal`
- `ziki resume goal-e2e-1` (persisted active goal) → guards pass, fails cleanly
  at provider config (`no provider configured`) — proves the store load path
- `ziki resume goal-wrong` → `error: no such goal in the store: goal-wrong`
- `ziki resume` with a completed goal → `error: goal already completed — nothing to resume`
- SIGTERM during a goal run against a hung endpoint: run aborted gracefully —
  `[ziki-state: idle] aborted by user`, `status: aborted`, and the stored goal
  JSON shows `"status":"aborted"`, `"progress":"aborted by user"` (mid-I/O
  abort + signal handling + persistence, end to end).
