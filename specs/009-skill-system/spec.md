# Feature Specification: Skill System — Load and Run Skills Like a Coding Editor

**Feature Branch**: `009-skill-system`

**Created**: 2026-08-23

**Status**: Draft

**Input**: User description: "Implement a full skill system for ziki, that loads skills and runs just like any coding editor like kimi. Skills are SKILL.md files with YAML frontmatter (name, description) and a markdown body. ziki must discover skills from project-level directories (.ziki/skills and .kimi-code/skills, for compatibility with existing kimi-code projects) and the user-level directory (~/.config/ziki/skills), expose them to the agent during goal execution (names + descriptions in the system prompt, full content on demand), and let interactive users list and inspect skills via /skill shell commands."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - The agent uses a skill to complete a goal (Priority: P1)

The user drops a skill into `.ziki/skills/my-skill/SKILL.md` (frontmatter: name, description; body: step-by-step instructions), then starts a goal whose completion requires following those instructions. The agent sees the skill in its context (name and description), fetches the full skill body on demand, follows it, and completes the goal. This is the core "runs just like any coding editor" behavior: skills are not inert documentation, they are executable guidance the agent actively consults.

**Why this priority**: A skill system whose agent cannot use skills is a file browser. Everything else exists to serve this story.

**Independent Test**: Start a goal against a workspace that contains one skill whose body instructs e.g. "always write files ending with the line SKILL-USED". With a scripted (fake) provider that calls the skill lookup and then writes a file, assert the resulting file follows the skill — proving lookup, content delivery, and agent integration end to end without a real network model.

**Acceptance Scenarios**:

1. **Given** a workspace with a valid skill in a skills directory, **When** a goal starts, **Then** the agent's system context lists the skill's name and description.
2. **Given** the skill is listed in the agent context, **When** the agent requests that skill's full content, **Then** the complete SKILL.md body is returned to the agent.
3. **Given** a goal whose completion criterion depends on following the skill's instructions, **When** the goal runs to completion, **Then** the produced artifacts follow the skill's instructions.

---

### User Story 2 - The user inspects skills from the shell (Priority: P1)

The user opens the ziki shell (REPL or one-shot command) and types `/skill list` to see every discovered skill with its name, description, and source location, and `/skill show <name>` to print a skill's full body. The commands work identically in one-shot and interactive modes, consistent with the existing /goal, /status, /provider command family.

**Why this priority**: Discoverability is what makes a skill system usable rather than a hidden feature. Interactive inspection is how users debug "why didn't the agent use my skill" without reading source code.

**Independent Test**: Run `ziki /skill list` and `ziki /skill show <known-skill>` against a fixture workspace; assert the output contains the skill name, description, source path, and full body respectively; assert `/skill show unknown` produces a clear error and a non-zero-exit-equivalent error message, not a crash.

**Acceptance Scenarios**:

1. **Given** a workspace with two skills across different source directories, **When** the user runs `/skill list`, **Then** both skills are listed with name, description, and the directory each was loaded from.
2. **Given** a discovered skill, **When** the user runs `/skill show <name>`, **Then** the full skill body is printed verbatim.
3. **Given** no skill of that name, **When** the user runs `/skill show <name>`, **Then** a clear "skill not found" message is printed listing the available skills.

---

### User Story 3 - Skills are discovered across project and user locations with predictable precedence (Priority: P2)

The user keeps personal skills in `~/.config/ziki/skills/` (available in every project), shared project skills in `.kimi-code/skills/` (checked into the repo, shared with the team; existing kimi-code projects work unmodified), and machine-local project overrides in `.ziki/skills/` (alongside the agent's other per-machine state, never committed — the natural place for "on my box, do it differently" tweaks). When the same skill name exists in several locations, the local project skill wins over the shared project skill, which wins over the user directory, and the listing shows the effective winner. Loading is resilient: a malformed or partially invalid skill never prevents the rest from loading.

**Why this priority**: Location conventions and precedence are what make skills portable between projects and machines. Robust loading (skip-and-warn, never crash) is what makes the system trustworthy in real repositories full of hand-edited markdown.

**Independent Test**: Point the loader at a fixture with a valid skill in each of the three locations, a duplicate name in two of them, plus a malformed frontmatter skill and an empty skill; assert the registry contains the deduplicated set with the documented precedence, and assert the malformed entries are skipped without error propagation.

**Acceptance Scenarios**:

1. **Given** skills with the same name in `.ziki/skills` (local project) and `~/.config/ziki/skills` (user), **When** skills are loaded, **Then** the local project skill is the one exposed (by name lookup and in listings).
2. **Given** a `.kimi-code/skills` directory from an existing kimi-code checkout, **When** skills are loaded, **Then** those skills are discovered without any project modification and can be committed to the repo like any other source.
3. **Given** a skills directory containing one skill with unparseable frontmatter next to three valid ones, **When** skills are loaded, **Then** the three valid skills load and the invalid one is skipped with a warning.

---

### Edge Cases

- No skills directory exists anywhere (fresh checkout): the agent runs exactly as before — zero skills listed, no error, no behavioral change to /goal.
- A skills directory exists but is empty: same as absent; no error.
- SKILL.md exists but the frontmatter is missing `name` or `description`, or the frontmatter block is unterminated: the skill is skipped with a warning naming the file; other skills still load.
- `name` in frontmatter disagrees with the directory name: the frontmatter `name` is authoritative; the directory name is only a discovery detail.
- Duplicate names across locations: precedence decides (local project `.ziki/skills` > shared project `.kimi-code/skills` > user `~/.config/ziki/skills`); the losing copies are not exposed under the same name.
- Skills in `.ziki/skills` are machine-local by design (the `.ziki` directory is the agent's gitignored state root); skills meant to be shared with the team belong in `.kimi-code/skills`. This is documented behavior, not a bug.
- A skill body is very large: loading succeeds; only the name/description enter the system context by default — the body is fetched on demand, so large skills do not bloat every turn.
- The agent (model) requests a skill that does not exist: a clear "unknown skill" error is returned to the model as the tool result, and the goal loop continues.
- A skills directory contains a nested directory without a SKILL.md: it is ignored silently (not a skill).
- Concurrent REPL and one-shot invocations: skills are read fresh per invocation; no caching state crosses process boundaries.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The system MUST treat as a skill any directory under a configured skills root containing a `SKILL.md` file whose first block is YAML frontmatter delimited by `---` lines carrying at least `name` and `description`.
- **FR-002**: The system MUST discover skills from these roots, in precedence order: `.ziki/skills` (project-local override, highest — machine-local by design, consistent with the gitignored `.ziki` state root), `.kimi-code/skills` (project-shared, committed to the repo, kimi-code compatible), `~/.config/ziki/skills` (user-global, lowest).
- **FR-003**: The system MUST parse each skill into name, description, source path, and full body; skills failing this parse MUST be skipped with a warning and MUST NOT abort loading of the remaining skills.
- **FR-004**: When multiple locations provide a skill with the same name, the system MUST expose exactly one, chosen by the FR-002 precedence order.
- **FR-005**: During goal execution the system MUST present every discovered skill's name and description in the agent's system context, so the model knows what is available.
- **FR-006**: During goal execution the model MUST be able to request a skill's full body by name on demand, receiving the verbatim content; requesting an unknown name MUST return a clear error message as the tool result (not a crash, not silence).
- **FR-007**: The shell MUST support `/skill list` (all skills: name, description, source) and `/skill show <name>` (full body), routed through the existing dispatcher and usable in one-shot and REPL modes.
- **FR-008**: `/skill` with no arguments MUST print usage; `/skill show` without a name MUST print a usage error; unknown subcommands MUST print the usage error, never crash.
- **FR-009**: Skill loading MUST be read-only at runtime: the system never writes, moves, or modifies skill files.
- **FR-010**: With zero discoverable skills, `/goal` MUST behave exactly as before this feature (no new failure modes, no context bloat beyond a fixed short notice).
- **FR-011**: Every new component MUST ship with unit tests proving the above (constitution Principle V: TDD, no exceptions), and `zig build test` MUST pass with all prior tests intact.

### Key Entities *(include if feature involves data)*

- **Skill**: an immutable loaded unit — `name` (authoritative, from frontmatter), `description` (one-line summary from frontmatter), `body` (verbatim markdown after the frontmatter), `source` (filesystem path it was loaded from, for listings and diagnostics).
- **Skill registry**: the deduplicated in-memory collection of loaded skills for one invocation; supports listing (ordered), lookup by exact name, and reporting which source each skill came from. Built fresh per invocation; never persisted.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A goal run in a workspace with one fixture skill completes with artifacts that follow the skill's instructions (agent integration proven end-to-end with a scripted provider).
- **SC-002**: `/skill list` and `/skill show <name>` produce complete, correct output in one-shot mode, and identical behavior in the REPL (covered by the existing shell test harness).
- **SC-003**: A skills tree containing invalid, duplicate, and edge-case skills loads to exactly the documented deduplicated set with zero crashes — verified by a fixture-based unit test.
- **SC-004**: `zig build test` passes with all pre-existing tests plus the new suite (no regressions; every FR above has at least one covering test).

## Assumptions

- The skill file convention follows the kimi-code `SKILL.md` format: `---`-delimited YAML frontmatter with `name` and `description` string fields, followed by a markdown body. Only simple scalar `key: value` frontmatter fields are required; exotic YAML (anchors, multiline literals beyond the two required fields) is out of scope for v1 parsing.
- The `.ziki` directory is the agent's machine-local state root (already gitignored), so `.ziki/skills` is a local override layer rather than a committed location; shared project skills live in `.kimi-code/skills`. Changing the `.ziki` gitignore treatment is explicitly out of scope.
- Skill directories are exactly one level deep under each root (`<root>/<skill-dir>/SKILL.md`); deeper nesting is not scanned.
- Skills are read-only inputs at runtime; authoring, validating, or scaffolding skills is out of scope for this feature.
- The agent integration is limited to context listing (FR-005) plus on-demand full-content lookup (FR-006); automatic skill triggering (the system deciding to follow a skill without the model asking) is explicitly out of scope — the model drives, the system serves.
- Per-invocation loading is acceptable (skills are re-read on each process start); cross-process caching is out of scope.
