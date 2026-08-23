# Implementation Plan: ziki Production-Ready for Small Autonomous Jobs

**Branch**: `010-small-job-production-ready` | **Date**: 2026-08-23 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/010-small-job-production-ready/spec.md`

## Summary

Makes `ziki` safe and reliable for small autonomous coding jobs (e.g. applying a
CodeRabbit review-fix locally). Six functional requirements close the real
failure modes observed while running ziki on such a job: home-directory path
expansion (FR-001), a guard on remote `git push` (FR-002), support for
long-running validation without a silent timeout (FR-003), an explicit
completion criterion before "done" (FR-004 — already wired via `--criterion`,
this plan confirms and hardens it), a clean working tree after the job (FR-005),
and a per-job report of changes/skips/push (FR-006).

Changes are deliberately scoped to the 6 FRs and keep the existing interface-first
(DIP) architecture: tools depend on `Fs`, the executor depends on `Provider`/
`Tool[]`/`GoalRepository`/`Fs`. No new provider/tool kinds are introduced.

## Technical Context

**Language/Version**: Zig 0.15.2.

**Primary Dependencies**: Zig stdlib only. Path expansion uses
`std.process.getEnvVarOwned(alloc, "HOME")` (there is no `std.os.getenv`/
`expandTilde` in the stdlib). Long-command handling reuses the existing
single-threaded `poll()` drain loop in `src/tool/bash.zig`.

**Storage**: Unchanged — goal state JSON under `.ziki/` (`FsGoalRepository`).

**Testing**: `zig build test` aggregates every module imported by `tests.zig`.
In-memory `FakeFs`/`FakeProvider` keep the executor loop testable. FR-005's git
tree handling is tested with a real throwaway temp git repo (git is assumed
available per spec Assumptions). FR-001/FR-003 use targeted unit tests.

**Target Platform**: macOS / Linux terminal (x86_64 + aarch64), single static
binary (already the case).

**Project Type**: CLI (autonomous agent session). No visual layer.

**Performance Goals**: SC-003 — validation suites complete and results captured
in < 15 min. FR-003's opt-in no-timeout mode makes this achievable.

**Constraints**: No unguarded remote push (FR-002). No silent tree modifications
left behind (FR-005). Minimal blast radius: cleanup only reverts drift the agent
introduced this run and never touched before the run.

**Scale/Scope**: Single-repo, local-apply "small jobs" (spec Assumptions).
Multi-repo refactors out of scope.

## FR-by-FR Design

### FR-001 — Home-directory (`~`) expansion (file tools)
- Add a free function `fs.expandTilde(alloc, path) ![]u8` in `src/fs/fs.zig`.
  It returns the path unchanged when it does not start with `~`; otherwise it
  reads `HOME` via `std.process.getEnvVarOwned` and, for `~/...`, joins
  `HOME` + the remainder (for a bare `~` it returns `HOME`). Falls back to the
  original path if `HOME` is unset.
- Call `expandTilde` inside `RealFs.resolve` in `src/fs/fs.zig` **before** the
  `isAbsolute` check, so every real file-path argument the tools pass through
  `RealFs` (read/edit/write **and** search) is expanded. This is the minimal
  single touch-point and covers all file tools at once.
- Test: `expandTilde` maps `~/foo` → `$HOME/foo` (and `~/` and bare `~`).

### FR-002 — Remote push authorization gate
- Give `BashTool` an `allow_push: bool` field (default `false`) and a helper
  `isUnauthorizedGitPush(cmd) bool` (tokenizes; true for `git push …` that is
  not `--dry-run`). Current `git push` (default remote) is also blocked.
- In `BashTool.execute`, if `!allow_push` and the command is an unauthorized
  `git push`, refuse with a clear `ToolResult` error message instead of spawning.
  Otherwise run normally; set `push_occurred = true` when an authorized push
  succeeds. Track `push_blocked`/`push_occurred` as `BashTool` fields so the
  report (FR-006) can read them after the run.
- Expose `--allow-push` on `/goal` in `src/main.zig`; pass it into
  `BashTool.init(fs, allow_push, timeout_seconds)`.
- Tests: `isUnauthorizedGitPush` for `git push origin main`, `git push`,
  `git push --dry-run origin main` (false), `echo hi` (false); and a
  `BashTool` refusal returns `ok=false` with a "blocked" message.

### FR-003 — Long-running validation
- Add `timeout_seconds: u64` to `BashTool` (default `600`, unchanged behavior).
- Add `const no_timeout = std.math.maxInt(u64)`. In `runWithTimeout`, skip the
  kill check when `timeout_seconds == no_timeout`.
- Expose `--timeout <N>` (seconds) and `--no-timeout` on `/goal`; default stays
  600. The job runner passes the chosen value into `BashTool.init`.
- Tests: a `sleep` longer than the configured timeout is killed (existing +
  new small-timeout case); with a large/`no_timeout` budget the same `sleep`
  completes and its output is captured.

### FR-004 — Explicit completion criterion (already supported; confirmed)
- The executor already routes a goal **with** `criterion` through `verify()`
  (YES/NO LLM check) and never declares done on the model's bare final message
  (the no-criterion branch is the only one that does). `--criterion` is already
  parsed in `src/main.zig` and stored on `Goal`.
- This plan leaves the mechanism in place; no code change required. Confirmed by
  the existing `GoalExecutor honours an explicit completion criterion` test.
  Trade-off: the criterion is a free-text verification prompt (not a fixed
  command list) — matches the spec's "for example, named checks must pass" and
  keeps the model as the judge, consistent with the existing design.

### FR-005 — Clean working tree after the job
- The executor captures a `pre_existing` snapshot of `git status --porcelain`
  paths at the **start** of `run()` (only if a git repo is present; failure is
  ignored so non-git/CI dirs are unaffected).
- `GoalExecutor` records **intentional** file changes: every file path written
  or edited via the `write_file`/`edit_file` tools during the run.
- At the end of `run()` (every terminal state), `cleanupTree` reverts only files
  that are (a) currently modified/untracked per `git status`, (b) NOT in the
  intentional set, and (c) NOT in `pre_existing`. Tracked drift is reverted with
  `git checkout -- <path>` (and `git restore --staged` first); untracked files
  that appeared this run are removed. Pre-existing user state is never touched.
- Pure helpers live in `src/agent/executor.zig` (testable without spawning git):
  `gitStatus(alloc, cwd) []u8` (swallows errors → `""`), `parseStatusPaths`,
  `revertIncidental(alloc, cwd, intentional, pre_existing) []const u8`.
- `--no-clean` on `/goal` disables reversion (safety escape hatch); default ON.
- Test: `parseStatusPaths` unit test; `revertIncidental` integration test with a
  real temp git repo (committed file modified + untracked file added → only the
  drift is reverted, intentional/pre-existing untouched).

### FR-006 — Per-job report
- `GoalExecutor` accumulates a `JobReport` (changed files, skipped reasons,
  push state) during `run()` and stores it on the executor as a heap slice
  (owned by `self.alloc`) so `main.zig` can print it after `ex.run`.
- `main.zig` reads `bt.push_occurred`/`bt.push_blocked` (FR-002 state) and
  `ex.report`, then prints the final block:
  `changed: … / skipped: … / push: <occurred|blocked|not requested>`.
- Skipped reasons captured: push blocked (FR-002), completion criterion
  unsatisfied after retries, aborted by user / turn budget.

## Constitution Check

| Principle | Plan compliance | Status |
|-----------|-----------------|--------|
| I. SOLID (SRP) | Path expansion lives in `fs`; push gating in `BashTool`; tree cleanup in `GoalExecutor`; reporting in `main.zig`. Each module keeps one reason to change. | PASS |
| I. SOLID (OCP) | New behavior added as new fields/functions behind existing interfaces; no branching on tool/provider kind. | PASS |
| I. SOLID (LSP) | `BashTool`/`Fs`/`GoalExecutor` keep their existing vtables; FRs are additive. | PASS |
| II. DIP / Interface-First | Tools still depend only on `Fs`; executor on injected `Fs`/`Provider`/`Tool[]`/`Repo`. Git cleanup is an executor-internal detail, not a new boundary. | PASS |
| III. Open/Closed | No edits to stable provider/tool selection logic. | PASS |
| IV. DRY | Shared `expandTilde`, `parseStatusPaths`, `isUnauthorizedGitPush` helpers; single timeout handling path. | PASS |
| V. TDD | Every FR ships a test (RED→GREEN): `expandTilde`, `isUnauthorizedGitPush`, timeout, `parseStatusPaths`/`revertIncidental`, report. | PASS |

No gate violations.

## Project Structure (changes only)

```text
specs/010-small-job-production-ready/
├── plan.md              # this file
├── tasks.md             # generated by /skill:speckit-tasks
└── spec.md              # existing

src/
├── fs/fs.zig            # +expandTilde (free fn); RealFs.resolve expands ~
├── tool/bash.zig        # +allow_push, +timeout_seconds, +no_timeout, push state, gate
├── agent/executor.zig   # +pre_existing snapshot, intentional-change tracking,
│                        #   cleanupTree, JobReport, FR-006 assembly
└── main.zig             # +--allow-push, --timeout, --no-timeout, --no-clean flags;
                         #   pass to BashTool; print JobReport
tests.zig                # unchanged (imports already cover touched modules)
```

**Structure Decision**: Additive edits only. No new files/modules; no new tool
or provider types. Keeps the constitution's interface-first layout intact.

## Complexity Tracking

No violations. (Constitution gate passed cleanly; all FRs are additive.)
