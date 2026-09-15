# Implementation Plan: [Lane A] Goal loop hardening: resume, budgets, compaction, abort

**Branch**: `013-goal-loop` | **Spec**: `specs/013-goal-loop-hardening/spec.md` | **Issue**: #16

## Summary

Harden the goal execution loop's four missing edges: (1) a resume path that loads a persisted goal + its conversation transcript from `FsGoalRepository` and continues the run, (2) token usage accounting with context compaction and a hard token budget, (3) time budget enforcement in the turn loop, (4) mid-turn abort observation (tool dispatch boundaries, Bash child kill, provider I/O abandon-and-discard, SIGINT/SIGTERM → stop file).

## Technical Context

- **Language/Build**: Zig 0.15.2 (CI gate `zig 0.15.2 build test`; 0.16.0 preview tracked). No external deps.
- **Architecture**: hexagonal-ish DI. `GoalExecutor` depends only on injected `Provider`, `Tool[]`, `GoalRepository`, `Fs` vtables. All state flows through `Goal` (persisted by `FsGoalRepository` at `<dir>/goal.<session>.json`).
- **Key existing pieces**:
  - `src/agent/executor.zig` — `run()` turn loop: one arena for the whole conversation, `messages: ArrayList(ChatMessage)`, stop file checked at top of loop only, turn budget checked, no token/time accounting, no compaction, no resume seeding.
  - `src/goal/repository.zig` — `GoalRepository` vtable (`save`/`load`) over `goal.<session>.json`; persists budgets/used but not the transcript.
  - `src/main.zig` — `runGoal()` always `Goal.init(...)` fresh; `/stop` writes `stop.<session>` file; dispatcher registers `goal/stop/provider/status/goals/skill/help`.
  - `src/tool/bash.zig` — `runWithTimeout` polls child pipes every 200 ms; per-command timeout; no abort observation.
  - `src/provider/provider.zig` — `ChatResponse` has no usage field; `CompletionRequest.budget_tokens` unused.
  - `src/provider/fake.zig` — `FakeProvider`/`FlakyProvider` scripted test providers.
- **Constitution alignment (DIP/ISP/OCP)**: new seams are injected interfaces (`StopProbe`, history on the repository vtable), not concrete leaks; provider change is additive data (`usage`), no branching.

## Technical Decisions

### D1 — Resume data model: persist the transcript, not a summary
The transcript (all `ChatMessage`s, including the original system + goal user message) is stored by `FsGoalRepository` at `<dir>/history.<session>.json` as `{"goal_id": "...", "messages": [...]}`. Resume loads it and, when `goal_id` matches, seeds the conversation verbatim (guaranteeing the model sees the same context it built up). Missing/corrupt file → empty history (resume still works from goal state alone). Fresh `/goal` clears it. Chosen over persisting summaries: faithful replay is simpler, testable (round-trip), and satisfies "resumes from its saved progress rather than restarting" (spec 005 FR-008). `GoalRepository.VTable` gains `save_history`/`load_history`/`clear_history` — single implementor (`FsGoalRepository`), tests exercise it through the interface.

### D2 — Token accounting: reported usage, estimated fallback
`ChatResponse` gains `usage: ?TokenUsage` (prompt/completion totals). `openai.zig` parses `usage.prompt_tokens`/`usage.completion_tokens` when present (additive; providers that omit it leave null). The executor adds reported usage to `goal.used.tokens`; when null it estimates `(sum of message content bytes + tool-call JSON) / 4` per request. This keeps enforcement real for fake providers (tests script `usage` directly) and honest for real ones.

### D3 — Budget/compaction policy (deterministic, testable)
After each turn's messages are finalized:
1. `used.tokens += turn_tokens` (reported or estimated).
2. If `used.tokens < max_tokens` → continue.
3. Else if compaction can drop ≥1 middle message → compact: retain `messages[0]` (system), `messages[1]` (goal), a compaction notice, and the last `retain_recent` (default 8) messages; rebuild the list in a fresh arena and reset the old arena (bounded memory); subtract dropped tokens from `used.tokens`; add a job-report line "context compacted".
4. Else → graceful stop: `status = .aborted`, progress "aborted: token budget exceeded", persisted, no further calls (matches the existing turn-budget stop status so budget stops are uniform).

### D4 — Time budget: wall clock in the turn loop
Executor records run-start wall time; `used.seconds = carried_seconds (persisted at run start) + elapsed_this_run`. Checked at the top of every turn (before the stop-file check ordering: stop → time → turn budget → token). `--timeout <s>` sets `budgets.max_seconds`; `--no-timeout` sets it to `maxInt(u64)` (matching Bash tool semantics). Exceedance → same graceful stop shape as D3 ("aborted: time budget exceeded").

### D5 — Mid-turn abort: injectable stop probe + poll loops
New seam `StopProbe = struct { ctx: *anyopaque, check: *const fn (*anyopaque) bool }`:
- **Executor**: default probe = stop-file existence (`fs.exists("<dir>/stop.<session>")`). Checked (a) at top of loop (existing), (b) before each tool dispatch within a turn, (c) immediately after a provider completion returns, (d) inside the provider I/O wait and retry sleeps.
- **Provider I/O**: `completeInterruptible` runs `provider.complete` on a worker thread with its own page_allocator-backed arena; the caller polls the probe every 50 ms. If the probe fires, the caller abandons the wait (thread joins-or-leaks deliberately; its arena is never freed on the abort path — bounded, intentional), discards any late result, and aborts the goal. On the normal path the thread is joined and the arena freed. Retry loop keeps 3 attempts/200 ms backoff, but each sleep/attempt boundary is probe-checked.
- **Bash tool**: optional `stop` probe field; `runWithTimeout`'s existing 200 ms poll loop checks it and SIGTERMs the child, returning `ok=false, error_message="run_command aborted by user"`, setting `bash.aborted = true`. The executor maps an aborted tool result straight to goal abort.
- **main.zig**: builds a file-based probe for both `/goal` and `/resume`; installs SIGINT/SIGTERM handlers (async-signal-safe `write(2)` to the pre-computed stop path) so Ctrl-C aborts gracefully and saves state; handlers restored after the run.

### D6 — Resume CLI wiring (minimal Lane C conflict surface)
`main.zig`: new `runResume()` mirrors `runGoal()`'s provider/tool construction but loads the goal via `repo.load()` and the history via `repo.loadHistory()`, refuses the FR-002 cases, resets status to `active`, and runs. Dispatcher gains `"resume"`; `main()` accepts bare `ziki resume [goal-id] <flags>` by rewriting to `/resume ...`. `runGoal()` clears history at start. Shared provider/transport construction is factored into a `buildProviderRuntime()` helper used by both paths (tool wiring order preserved verbatim to minimize the diff Lane C will rebase onto).

## Data Flow (resume)

```
ziki resume goal-X [--provider p] [-v]
  → repo.load() → Goal (id/objective/budgets/used/status)
  → guards: none → "no goal to resume"; id mismatch → "no such goal"; terminal → refuses
  → repo.loadHistory() → transcript (goal_id match) or empty
  → status := .active; progress := "resumed"
  → GoalExecutor.run() with seeded messages; loop continues turn N+1
  → each turn end: repo.save(goal) + repo.saveHistory(goal.id, messages)
```

## Risks / Trade-offs

- **Abandoned provider thread** leaks its arena (KBs) and dies with the process — accepted; socket-level cancel is out of scope (transport timeouts still bound the I/O).
- **Compaction loses detail** (trimmed middle turns) — standard agent-loop trade-off; retained window is recent turns; the goal message and criterion stay.
- **Estimated token counts** (chars/4) under-count some encoders — budget is a guardrail, not billing; reported usage is preferred when present.
- **main.zig touched** → coordinate with Lane C (tool wiring kept verbatim; resume is a separate function; land in separate PRs, rebase whichever lands second).

## Milestones

1. M1: provider `usage` + openai parsing + repository history (data layer green).
2. M2: executor budgets + compaction (token/time/turn uniform stops) green.
3. M3: executor mid-turn abort (probe, dispatch checks, provider I/O discard) green.
4. M4: resume CLI + history seeding + signal handlers green; `zig build test` fully green.
