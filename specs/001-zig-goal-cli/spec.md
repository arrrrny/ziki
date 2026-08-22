# Feature Specification: Zig Goal CLI

**Feature Branch**: `[001-zig-goal-cli]`

**Created**: 2026-08-22

**Status**: Draft

**Input**: User description: "kimi is great, I am already running a custom patched version of it, goal setting is perfect, it gets job done, the only problem it has is that it is typescript, it eats up a lot of memory, when I have 20 windows open it easily fills over 10GB memory, there is a remedy for that, the amazing programming language zig, I believe it can easily cut down to thew 1/3 of resource probably 1/8. While I dont want to sacrifice any of the kimis features, the only things I dont care is that I only need opencode,kilo,z.ai,kimi and open-ai custom providers, we dont need any of the rest. what I care MOST is the goal feature. so prioritize an mvp with a goal setting, also since I use spec driven development, we will create a ziki speckit integration, thats not directly part of this, but keep that in mind. Definition of done: Slash command goal and a given goal is completed just like using kimi, any cosmetic, theming not important at all."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Define and complete a goal autonomously (Priority: P1)

A developer opens the CLI, types the `/goal` slash command with a natural-language objective (and optionally a completion criterion), then lets the agent pursue the goal on its own. The agent reads, edits, searches, and runs commands in the working directory, makes progress without per-step prompting, and reports when the goal is met. This mirrors the existing Kimi `/goal` behavior the user already relies on.

**Why this priority**: This is the explicit Definition of Done. Everything else is secondary; without a working goal feature the project has no value to the user.

**Independent Test**: Implement only this story and verify a representative coding goal (e.g., "add a function that does X and make the existing tests pass") is driven to completion end-to-end with no further human input, producing the same outcome Kimi would.

**Acceptance Scenarios**:

1. **Given** the CLI is running with a valid provider configured, **When** the user issues `/goal <objective>` and provides the completion criterion, **Then** the agent begins pursuing the goal autonomously and stops only when the criterion is satisfied.
2. **Given** an in-progress goal, **When** the agent reaches the completion criterion, **Then** it reports the goal as completed with a summary of what was done.
3. **Given** an in-progress goal that cannot be satisfied (blocked), **When** the agent exhausts its reasonable options, **Then** it reports the blocker clearly and stops rather than looping.

---

### User Story 2 - Run many windows within a tiny memory budget (Priority: P2)

The same developer runs 20 or more CLI windows simultaneously (one per project/task) and the combined resident memory stays a small fraction of the current TypeScript-based baseline, which fills over 10 GB at that scale.

**Why this priority**: The entire motivation for the rewrite is memory. A single working goal feature that still blows past 10 GB defeats the purpose.

**Independent Test**: Launch 20 concurrent agent windows each with a live/active goal and measure total resident memory; it must be at most one-eighth of the baseline (~10 GB), i.e. around 1.25 GB or less.

**Acceptance Scenarios**:

1. **Given** 20 agent windows each pursuing or holding a goal, **When** memory is measured at steady state, **Then** total resident memory does not exceed one-eighth of the current baseline.
2. **Given** a single idle window, **When** memory is measured, **Then** its footprint is a small, bounded baseline cost (no per-window memory bloat).

---

### User Story 3 - Connect to the required providers (Priority: P3)

The CLI must connect to exactly the providers the user cares about: opencode, kilo, z.ai, kimi, and OpenAI-compatible custom endpoints. Every other provider integration from Kimi is intentionally dropped.

**Why this priority**: The agent cannot complete goals without a working model backend. Provider breadth beyond the five named is explicitly unwanted, so this is bounded, not open-ended.

**Independent Test**: For each of the five providers, configure credentials/endpoint and complete at least one goal end-to-end; confirm the other (dropped) providers are not present.

**Acceptance Scenarios**:

1. **Given** credentials for any one of the five required providers, **When** the user sets it as the active provider, **Then** goals are completed using that provider.
2. **Given** a custom OpenAI-compatible endpoint URL and key, **When** configured, **Then** that endpoint serves as the goal-driving model.
3. **Given** no provider configured, **When** the user issues `/goal`, **Then** the CLI reports a clear "no provider configured" error instead of failing obscurely.

---

### User Story 4 - Resume a goal across restarts (Priority: P4)

A goal's state (objective, status, progress, budget) persists so that if the window/process restarts, the same goal can be resumed without re-defining it.

**Why this priority**: Power users keep many windows open for long periods; durability makes the goal feature dependable. It is not part of the minimal DoD but is low-risk and high-value.

**Independent Test**: Start a goal, kill the process mid-way, relaunch pointed at the same state, and confirm the goal resumes from where it stopped rather than starting fresh.

**Acceptance Scenarios**:

1. **Given** an active goal with partial progress, **When** the process is restarted and the saved state loaded, **Then** the agent resumes the same goal instead of re-prompting for it.
2. **Given** a completed goal, **When** the state is reloaded, **Then** it is shown as completed with its summary.

---

### Edge Cases

- A goal is impossible or blocked: the agent must report the blocker and stop (no infinite loops).
- No provider or invalid credentials: clear, actionable error before any goal work begins.
- Token / time / turn budget exceeded: stop gracefully and report what was accomplished.
- Context window limits reached: compact/summarize prior context so work continues (like Kimi).
- Multiple windows point at the same working directory: each window's goal state stays isolated and does not corrupt the other's work.
- Malformed or empty `/goal` input: reject with guidance on the expected format.
- Active provider endpoint is unreachable mid-goal: surface the failure and allow retry/reconfigure.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST provide a `/goal` slash command that accepts a natural-language objective and an optional, explicit completion criterion.
- **FR-002**: System MUST autonomously pursue the set goal across multiple turns without requiring per-step user input, until the completion criterion is met or a stop condition occurs.
- **FR-003**: System MUST report goal status (in-progress, completed, blocked, aborted) and a final summary of work performed in a clear, human- and machine-readable form.
- **FR-004**: System MUST support exactly these providers: opencode, kilo, z.ai, kimi, and OpenAI-compatible custom endpoints; all other Kimi provider integrations are excluded.
- **FR-005**: System MUST allow the active provider, model, endpoint, and credentials to be configured globally or per session.
- **FR-006**: System MUST persist goal state (objective, status, progress, budgets, timestamps) so it survives process restarts and can be resumed.
- **FR-007**: System MUST expose the tooling needed to complete coding goals — file read/edit, content search, and command execution — with capability equivalent to Kimi's.
- **FR-008**: System MUST provide a stop/abort command to terminate an in-progress goal at any time.
- **FR-009**: System MUST keep memory usage bounded and small per window so that running many concurrent windows does not approach the current TypeScript baseline's footprint.
- **FR-010**: System MUST report a clear, actionable error when no valid provider is configured, when credentials are invalid, or when the active endpoint is unreachable.

### Key Entities *(include if feature involves data)*

- **Goal**: The unit of autonomous work. Attributes: objective text, completion criterion, status (active / completed / blocked / aborted), progress indicator, budgets (turns, tokens, time), creation and last-updated timestamps, owning session id.
- **Provider**: A model backend connection. Attributes: name, kind (one of the five required), endpoint URL, credentials, selected model.
- **Session / Window**: One running agent instance. Attributes: working directory, active provider reference, associated goal reference, lifecycle state.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A user can define a goal via `/goal` and the system completes it end-to-end without manual per-step intervention, producing the same outcome as the current Kimi goal feature for representative coding tasks. (Definition of Done)
- **SC-002**: Memory consumption at 20 concurrent windows is reduced to at most one-eighth of the current TypeScript-based baseline (from over 10 GB down to roughly 1.25 GB or less).
- **SC-003**: The five required providers (opencode, kilo, z.ai, kimi, OpenAI-compatible custom) are each usable to drive at least one goal to completion end-to-end.
- **SC-004**: A goal's state survives a process restart and resumes without re-definition, with no loss of already-completed progress.
- **SC-005**: Blocked or unachievable goals are detected and reported clearly, and the agent stops rather than looping indefinitely.

## Assumptions

- **Implementation language**: The user has mandated Zig as the implementation language specifically to achieve the memory reduction; this is a hard constraint, not a suggestion. (Technology choice for the means; the Success Criteria remain behavior-focused.)
- **Provider scope**: Only the five named providers are required; every other provider supported by Kimi is intentionally out of scope and may be removed.
- **Goal semantics**: The `/goal` behavior should mirror the existing Kimi `/goal` the user already runs (natural-language objective + completion criterion + autonomous pursuit to a stop condition). No new goal UX is required beyond parity.
- **Operating mode**: The CLI runs in a terminal as an interactive agent session (REPL/TUI) like Kimi; exact visual design is unspecified and explicitly not important.
- **Cosmetic scope**: Theming, colors, and visual polish are out of scope for the MVP and for this feature overall.
- **Future integration**: A "ziki speckit" Spec-Driven-Development integration is anticipated but is NOT part of this feature; the design should not preclude it.
- **Tooling parity**: The agent needs at least the core Kimi tools (read, edit, search, run commands) to complete coding goals; broader Kimi features may be deferred beyond the MVP as long as the goal feature and required providers work.
