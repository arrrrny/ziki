# Feature Specification: Production safety — push-gate hardening, already-applied detection, report completeness

**Feature Branch**: `016-production-safety` | **Issue**: [#19](https://github.com/arrrrny/ziki/issues/19) (Lane D) | **Created**: 2026-09-15

**Input**: Issue #19 verbatim tasks (audit baseline: spec 010 strict 50% — production guards are bypassable).

## User Scenarios & Testing *(mandatory)*

### US1 — Harden the git push gate (P1)
`isUnauthorizedGitPush` only pattern-matches the command string; `cd repo && git push`, `sh -c 'git push'`, and configured aliases bypass it. Approve based on resolved intent — parse compound commands, option flags, and shell wrappers — not raw text.
**AS-1**: `cd repo && git push` → gated. **AS-2**: `sh -c 'git push'` (and bash/zsh/dash `-c`) → gated. **AS-3**: `git -C repo push` → gated. **AS-4**: An unknown `git <sub>` (possible alias) → gated (fail closed). **AS-5**: Safe shapes (`git status`, `git push --dry-run`, `echo git push`) stay allowed. Every listed bypass shape has a failing-before/passing-after test.

### US2 — Already-applied detection (P2)
Before running a fresh goal that has a completion criterion, run one cheap verification pass; when the criterion already holds, short-circuit with "already done" instead of burning provider turns.
**AS-1**: Criterion already satisfied → goal completes after exactly one provider call (the check), progress says "already done", no tool dispatch. **AS-2**: Not satisfied → the loop proceeds unchanged.

### US3 — Job report completeness (P2)
**AS-1**: For a scripted scenario the job report covers intentional changes (including untracked new files), lists reverted incidental drift, keeps pre-existing untracked user files untouched, and reports no skips — asserted near-exactly.

## Requirements
- **FR-001**: The push gate resolves intent: top-level compound separators (`&&`, `||`, `;`, `|`, quote-aware), shell wrappers (`sh`/`bash`/`zsh`/`dash -c`), and `git` global options (`-C <path>`, `-c <k>=<v>`); unknown git subcommands fail closed; `--dry-run` stays safe.
- **FR-002**: Fresh goals with a criterion run a pre-check verification; short-circuit shape: `.completed`, progress "already done: …", job-report skip note, persisted.
- **FR-003**: No changes outside `src/tool/bash.zig` (gate), `src/agent/executor.zig` (pre-run check), and tests — per the issue's Touches list.

## Success Criteria
- SC-001: `zig build test` green; every listed bypass shape has a failing-before/passing-after test.
