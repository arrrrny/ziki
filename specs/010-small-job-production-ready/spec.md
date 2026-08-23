# Feature Specification: ziki Production-Ready for Small Autonomous Jobs

**Feature Branch**: `010-small-job-production-ready`

**Created**: 2026-08-23

**Status**: Draft

**Input**: User description: "for this project also run /skill:speckit-specify to make ziki production ready for the small jobs like this"

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Trustworthy end-to-end execution of a small job (Priority: P1)

A user delegates a small, well-scoped coding job (for example, applying a set of code-review fixes to a local repo). ziki reads the task, applies the changes, validates them, and reports a clear success or failure — without the user having to babysit it.

**Why this priority**: Trust is the whole point; if a small job can silently do the wrong thing or fail obscurely, the feature is unusable.

**Independent Test**: Delegate a small job whose changes are already applied; assert ziki detects this, reports success without modifying files, and leaves the tree clean.

**Acceptance Scenarios**:

1. **Given** a small job, **When** ziki finishes, **Then** it reports a clear success or failure with a per-step summary.
2. **Given** a job whose work is already done, **When** ziki inspects the repo, **Then** it reports done without modifying files or pushing.

---

### User Story 2 - No unguarded remote pushes (Priority: P2)

ziki can run git and may need to push, but it MUST NOT push to a shared remote without explicit authorization, so a user's pull requests are never touched unexpectedly.

**Why this priority**: An autonomous push to a real remote is a high-blast-radius action; it must be gated.

**Independent Test**: Delegate a job that would require a push; assert no push occurs unless an authorization gate is satisfied.

**Acceptance Scenarios**:

1. **Given** a job that completes with changes, **When** ziki reaches the push step, **Then** it requests authorization (or a dry-run) and does not push unless granted.
2. **Given** authorization is denied, **When** ziki cannot push, **Then** it reports the local result and stops without erroring the whole job.

---

### User Story 3 - Robust handling of environment quirks (Priority: P3)

ziki MUST handle common environment details so small jobs do not fail for trivial reasons: home-directory paths, long-running validation, and bounded command output.

**Why this priority**: These were the exact failure modes observed in testing; fixing them makes jobs reliable.

**Independent Test**: Delegate a job that references a home-directory path and requires running the project's test suite; assert both succeed.

**Acceptance Scenarios**:

1. **Given** a file path using home-directory shorthand, **When** ziki's file tools resolve it, **Then** the file is read/written correctly.
2. **Given** a validation step that runs longer than a single command window, **When** ziki executes it, **Then** validation completes and its result is captured.

---

### Edge Cases

- What if a file path uses `~`? → Must be resolved to the user's home directory.
- What if validation (for example, a full test suite) exceeds the command time budget? → Must not be killed silently; result must be captured or the limit raised.
- What if the job makes incidental changes (lockfile drift)? → Tree must be left clean; incidental changes reverted.
- What if the goal is already satisfied? → Must detect and stop without pushing.
- What if the model declares done prematurely? → An explicit completion check (for example, required checks pass) must gate completion.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST resolve home-directory shorthand in all file-path inputs (read, edit, write) so paths referencing the user home work correctly.
- **FR-002**: System MUST require explicit authorization (or an explicit dry-run mode) before pushing any commit to a shared remote.
- **FR-003**: System MUST complete validation steps even when they are long-running, capturing their result rather than aborting on a time limit.
- **FR-004**: System MUST support an explicit completion criterion (for example, named checks must pass) before declaring a job done.
- **FR-005**: System MUST leave the working tree clean after a job — reverting incidental changes and never leaving the repo in a modified state unless changes were intentionally made and reported.
- **FR-006**: System MUST report, per job, what was changed, what was skipped, and whether a push occurred.

### Key Entities *(include if feature involves data)*

- **Job**: A goal delegated to ziki, described in natural language, optionally with a completion criterion.
- **Tool**: A capability ziki uses (run a command, read/edit/write a file, search).
- **Job Report**: The final summary of changes, skips, and push status.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% of "already applied" small jobs are correctly identified with zero file changes and zero pushes.
- **SC-002**: 0 unintended remote pushes occur without explicit authorization across a sample of 20 delegated jobs.
- **SC-003**: Small jobs that require running the project's validation suite complete and capture results in under 15 minutes.
- **SC-004**: 100% of file-path inputs using home-directory shorthand resolve correctly.

## Assumptions

- ziki executes on the user's machine or an equivalent environment with git and the relevant language toolchains installed.
- Authorization for push is supplied out-of-band (explicit flag, config, or interactive gate), not assumed.
- "Small jobs" are scoped, single-repo, local-apply tasks; large multi-repo refactors are out of scope for v1.
- The underlying model provider is reachable (the existing proxy/provider configuration continues to apply).
