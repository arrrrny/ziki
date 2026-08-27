# Tasks: ziki Production-Ready for Small Autonomous Jobs

**Input**: Design documents from `/specs/010-small-job-production-ready/`

**Prerequisites**: plan.md (required), spec.md (required for user stories)

**Tests**: REQUIRED. The parent agent explicitly asked for tests (at minimum a
`~` expansion test). The constitution (Principle V) mandates TDD: write the test,
watch it fail (RED), then implement to green (GREEN).

**Organization**: Tasks grouped by user story from spec.md. FR-004 (completion
criterion) is already wired via `--criterion`; tasks confirm it rather than add
net-new code.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (US1..US3)
- Exact file paths included in descriptions

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Branch + spec artifacts already created (plan.md done). This phase
prepares the feature branch and confirms the build/test baseline.

- [ ] T001 Create branch `010-small-job-production-ready` from current HEAD and confirm `zig build` and `zig build test` baseline pass
- [ ] T002 Confirm FR-004 is already satisfied: `--criterion` parsed in `src/main.zig`, stored on `Goal`, and routed through `verify()` in `src/agent/executor.zig` (no net-new code)

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Shared helpers that multiple FRs depend on. Must be complete before
the user-story phases that use them.

- [ ] T003 [P] Add `fs.expandTilde(alloc, path) ![]u8` free function to `src/fs/fs.zig` (reads `HOME` via `std.process.getEnvVarOwned`; expands `~/x`→`$HOME/x`, bare `~`→`$HOME`; original path returned if no `~` or `HOME` unset)
- [ ] T004 [P] Add `no_timeout = std.math.maxInt(u64)` and refactor the kill check in `runWithTimeout` (`src/tool/bash.zig`) so a `no_timeout` budget skips the timeout check
- [ ] T005 [P] Add pure git-status helpers to `src/agent/executor.zig`: `gitStatus(alloc, cwd) []u8` (swallows errors → `""`), `parseStatusPaths([]const u8) [][]const u8`, and `revertIncidental(alloc, cwd, intentional, pre_existing) []const u8`

**Checkpoint**: All shared helpers exist; user-story work may begin.

---

## Phase 3: User Story 1 - Trustworthy end-to-end execution (Priority: P1) 🎯 MVP

**Goal**: A small job runs to completion, leaves the tree clean, and reports
what changed / what was skipped / whether a push happened (FR-004, FR-005, FR-006).

**Independent Test**: `zig build test` — executor test asserts a job that writes
a file ends with a populated `changed` report, a clean tree, and no push. An
"already applied" job leaves zero file changes and zero pushes.

### Tests for User Story 1 ⚠️

- [ ] T006 [US1] Write failing test: `parseStatusPaths` parses `git status --porcelain` output (modified + untracked lines) into path list — `src/agent/executor.zig`
- [ ] T007 [US1] Write failing integration test: `revertIncidental` over a real temp git repo reverts only drift (modified tracked file + newly-added untracked file), leaving pre-existing/intentional files untouched — `src/agent/executor.zig`
- [ ] T008 [US1] Write failing test: `GoalExecutor` accumulates a `JobReport` (changed files + skipped + push state) and stores it on the executor after `run` — `src/agent/executor.zig`

### Implementation for User Story 1

- [ ] T009 [US1] Wire `JobReport` into `GoalExecutor`: track intentional write/edit paths during `dispatch`, build the report string at terminal state, store on the executor (`src/agent/executor.zig`)
- [ ] T010 [US1] Implement tree cleanup in `GoalExecutor.run`: snapshot `pre_existing` at start, call `revertIncidental` at every terminal state (respect `--no-clean`); never touch pre-existing user state (`src/agent/executor.zig`)
- [ ] T011 [US1] Print the FR-006 job report in `src/main.zig` after `ex.run` (changed / skipped / push: occurred|blocked|not requested) and add `--no-clean` flag parsing in `runGoal`

**Checkpoint**: A job reports cleanly and leaves the tree clean; US1 independently functional.

---

## Phase 4: User Story 2 - No unguarded remote pushes (Priority: P2)

**Goal**: `git push` to a remote cannot happen without explicit authorization;
the report records whether a push was blocked or occurred (FR-002, FR-006 push).

**Independent Test**: `zig build test` — `isUnauthorizedGitPush` true for
`git push origin main` and bare `git push`, false for `git push --dry-run …` and
`echo hi`; `BashTool` with `allow_push=false` refuses a push command with a
clear error.

### Tests for User Story 2 ⚠️

- [ ] T012 [US2] Write failing test: `isUnauthorizedGitPush` classification in `src/tool/bash.zig`
- [ ] T013 [US2] Write failing test: `BashTool` with `allow_push=false` refuses an unauthorized `git push` (`ok=false` + "blocked" message); sets `push_blocked`; with `allow_push=true` runs it and sets `push_occurred` on success — `src/tool/bash.zig`

### Implementation for User Story 2

- [ ] T014 [US2] Add `allow_push`, `push_blocked`, `push_occurred` fields + `isUnauthorizedGitPush` helper to `src/tool/bash.zig`; gate `execute` before spawning; honor `BashTool.init(fs, allow_push, timeout_seconds)`
- [ ] T015 [US2] Parse `--allow-push` in `src/main.zig` `runGoal` and pass it (with the timeout) into `BashTool.init`; build the FR-006 push line from `bt.push_occurred`/`bt.push_blocked`

**Checkpoint**: No unguarded push; push status surfaces in the report.

---

## Phase 5: User Story 3 - Robust handling of environment quirks (Priority: P3)

**Goal**: Home-directory paths work in file tools, and long-running validation
is not silently killed (FR-001, FR-003).

**Independent Test**: `zig build test` — `expandTilde` maps `~/foo`→`$HOME/foo`;
a `sleep` longer than a small budget is killed, while the same `sleep` completes
under a large/`no_timeout` budget with output captured.

### Tests for User Story 3 ⚠️

- [ ] T016 [US3] Write failing test: `fs.expandTilde` resolves `~/foo`, `~/`, and bare `~` against `$HOME` — `src/fs/fs.zig`
- [ ] T017 [US3] Write failing test: `BashTool` honors a custom `timeout_seconds` (long `sleep` killed under small budget; completes under large/`no_timeout`) — `src/tool/bash.zig`

### Implementation for User Story 3

- [ ] T018 [US3] Call `expandTilde` inside `RealFs.resolve` (`src/fs/fs.zig`) before the `isAbsolute` check so read/edit/write/search paths all expand `~`
- [ ] T019 [US3] Pass `timeout_seconds` through `BashTool.execute` → `runWithTimeout`; add `--timeout <N>` and `--no-timeout` flags in `src/main.zig` `runGoal` (default 600)

**Checkpoint**: `~` paths and long validation both work; US3 independently functional.

---

## Phase 6: Polish & Cross-Cutting Concerns

- [ ] T020 [P] Run full `zig build test` suite — all green
- [ ] T021 [P] Run `zig build` and confirm the `ziki` binary builds
- [ ] T022 Final self-audit: confirm FR-001..FR-006 coverage, no constitutional violations (SOLID/DIP/TDD), minimal diff scoped to the 6 FRs

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: Branch/create artifacts — start immediately
- **Foundational (Phase 2)**: T003/T004/T005 — blocks all user-story phases
- **US1 (Phase 3)**: Depends on Foundational — delivers MVP (clean tree + report)
- **US2 (Phase 4)**: Depends on Foundational (T004 for no_timeout reuse optional)
- **US3 (Phase 5)**: Depends on Foundational (T003 expandTilde, T004 timeout)
- **Polish (Phase 6)**: Depends on all stories

### User Story Dependencies

- **US1 (P1)**: After Foundational. No dependency on other stories.
- **US2 (P2)**: After Foundational; uses `BashTool` fields + report.
- **US3 (P3)**: After Foundational; uses `expandTilde` + timeout refactor.

### Parallel Opportunities

- Phase 2 `[P]` tasks (T003/T004/T005) are independent files → run in parallel.
- Within each story, the `[P]` test tasks (T006/T007/T008, T012/T013, T016/T017)
  can be authored together (RED), then implemented together (GREEN).
- US1/US2/US3 implementations proceed sequentially here (single developer) but
  share only the Foundational helpers.

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Phase 1 (branch) + Phase 2 (helpers).
2. Phase 3 (US1): FR-005 clean tree + FR-006 report; confirm FR-004.
3. **STOP and VALIDATE**: `zig build test` green; US1 test passes → trustworthy run.

### Incremental Delivery

1. Setup + Foundational → helpers ready.
2. US1 → clean tree + report (MVP!).
3. US2 → push gate + report push state.
4. US3 → tilde expansion + long-running validation.
5. Polish → full suite + build.

---

## Notes

- Tests are REQUIRED and written first (parent agent directive + constitution V).
- Keep changes scoped to the 6 FRs; no new provider/tool kinds.
- FR-004 is already implemented via `--criterion`; tasks confirm, not add.
- Commit after each logical group; stop at each Checkpoint to validate.
