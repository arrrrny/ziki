# Contract: CLI Commands (`cli/cli.zig`)

The CLI is a line-oriented REPL. Each input line is one command. Unknown input
that is not a slash command is treated as a user message to the active goal (or
rejected if no goal is active). Version-agnostic; this is the user-facing
contract.

## Commands

### `/goal <objective>`

Starts (or replaces) the active goal.

- `objective`: free text, required, non-empty.
- Flags:
  - `--criterion "<text>"` (optional): explicit completion criterion (FR-001).
  - `--provider <name>` (optional): override active provider for this goal.
- Behavior: validates non-empty objective; errors clearly if no provider is
  configured (FR-010); otherwise hands off to `GoalExecutor` and runs the loop
  autonomously (FR-002). Prints status transitions (FR-003).

### `/stop`

Aborts the active goal (FR-008). Sets status `aborted`, prints summary of work
done. No-op with clear message if no active goal.

### `/status`

Prints the active goal: objective, status, progress, budgets used, updated_at.
If none active, prints "no active goal".

### `/provider [name]`

- With no arg: prints the active provider name + endpoint + model.
- With a name from the five required (opencode, kilo, z.ai, kimi,
  openai_custom): switches the active provider for subsequent goals (FR-005).
- Unknown provider name -> clear error; does not add providers outside the five
  (FR-004).

## Error contract (FR-010)

Every command that cannot proceed MUST print a single clear, actionable line
prefixed `error:`, e.g. `error: no provider configured — set one via /provider
or config`. It must NOT crash or loop.

## Output contract (FR-003)

Status changes are emitted as `status: <active|completed|blocked|aborted>` lines
plus a final `summary:` block when the goal ends.
