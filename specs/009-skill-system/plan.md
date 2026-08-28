# Implementation Plan: Skill System — Load and Run Skills Like a Coding Editor

**Branch**: `009-skill-system` | **Date**: 2026-08-23 | **Spec**: `specs/009-skill-system/spec.md`

**Input**: Feature specification from `/specs/009-skill-system/spec.md`

## Summary

ziki discovers `SKILL.md` skill files (kimi-code convention: `---` YAML frontmatter with `name` and `description`, markdown body) from three roots in precedence order — project-local `.ziki/skills` (machine-local override layer, gitignored by design alongside the agent's other `.ziki` state), project-shared `.kimi-code/skills` (committed, kimi-code compatible), and user `~/.config/ziki/skills` — into a deduplicated in-memory registry built fresh per invocation. During `/goal` execution every discovered skill's name and description is listed in the agent system prompt, and a new `skill` tool lets the model fetch any skill's full body on demand. Interactive users get `/skill list` and `/skill show <name>` through the existing shell dispatcher. Loading is skip-and-warn robust: malformed skills never abort the run, and with zero skills the agent behaves exactly as before (the tool is not even registered).

## Technical Context

**Language/Version**: Zig 0.15.2 (toolchain on box: `/workspace/herdr/.cache/zig/zig-x86_64-linux-0.15.2/zig`)

**Primary Dependencies**: none new — only `std` (JSON, fs, process env). The feature is pure additive composition over the existing boundaries.

**Storage**: filesystem only — skill files are read-only inputs; the registry is in-memory per invocation and never persisted (FR-009).

**Testing**: `zig build test` aggregator (`tests.zig`) + in-file `test` blocks (house pattern), FakeFs/FakeProvider for all boundaries. TDD per constitution Principle V.

**Target Platform**: native CLI binary, Linux (existing target).

**Project Type**: CLI coding agent (existing).

**Constraints**: low-footprint runtime is the project's reason for being (spec 008) — no background caching, no daemon, no persistent state; skill bodies enter the context only on demand (FR-005 lists only name+description).

**Scale/Scope**: tens of skills per project, skill files up to the existing 1 MiB read cap; discovery is one-level directory scan per root.

## Constitution Check

*Gate: SOLID, no exceptions (constitution v1.1.0).*

- **SRP**: skill parsing (`skill.zig`), discovery/dedup (`registry.zig`), agent-facing tool (`tool.zig`), shell command (`handler.zig`) are four separate modules, each with one reason to change; the executor learns only of a preformatted listing string, not the skill domain.
- **OCP**: adding a skill = adding a directory — zero code change. Adding a skills *root* = one entry in the composition-root roots list. The `Fs` boundary gains one additive operation (`readDir`) rather than being edited per-consumer.
- **LSP**: `SkillTool` is a drop-in `Tool` vtable implementation, substitutable wherever `Tool` is used; `RealFs`/`FakeFs` both satisfy the extended `Fs` contract.
- **ISP**: `GoalExecutor` depends on `?[]const u8 skills_listing` and the `Tool` set — no skill-specific interface leaks into the agent layer.
- **DIP**: the registry depends on the `Fs` interface (never `std.fs` directly), so all discovery/precedence logic is FakeFs-testable; the shell handler depends on the registry, injected at the composition root.
- **TDD (Principle V)**: every module ships with tests written against the spec's FRs; the task list orders tests first.

No violations. Post-design re-check: unchanged.

## Project Structure

### Documentation (this feature)

```text
specs/009-skill-system/
├── spec.md              # WHAT: user stories, FRs, success criteria
├── plan.md              # This file: design decisions
└── tasks.md             # Task breakdown (speckit-tasks output)
```

### Source Code (repository root)

```text
src/skill/               # NEW package
├── skill.zig            # Skill entity + frontmatter parser (pure)
├── registry.zig         # Discovery over Fs, precedence, dedup, warnings
├── tool.zig             # SkillTool: agent-facing fetch-by-name Tool
└── handler.zig          # /skill list|show command logic (returns text)
src/fs/fs.zig            # MODIFIED: add readDir to Fs/RealFs/FakeFs (additive)
src/agent/executor.zig   # MODIFIED: optional skills_listing in system prompt
src/main.zig             # MODIFIED: composition root wiring (registry, tool,
                         #   handler registration, /help line)
tests.zig                # MODIFIED: aggregator imports for the new package
```

## Architecture & Key Decisions

- **Skill format parsing is a pure function** (`skill.parse`): bytes in, `Skill{name, description, body, source}` out or a typed error. Strict frontmatter (must open with a `---` line, must close with a `---` line; `name`/`description` required, optional surrounding quotes stripped). The frontmatter `name` is authoritative over the directory name (spec edge case). Testable without any filesystem.
- **Discovery needs directory enumeration; the `Fs` boundary does not have it yet.** The registry must not touch `std.fs` directly (DIP), so `Fs` gains one additive vtable operation: `readDir(ctx, alloc, path) ![][]const u8` returning direct entry names. `RealFs` implements it with `std.fs` iteration; `FakeFs` synthesizes direct children from its flat path map (sufficient because the registry probes `<root>/<entry>/SKILL.md` via `exists`+`readFile`, which stay the source of truth). Additive interface extension is the OCP-blessed move; existing consumers are untouched.
- **Precedence is load order, dedup is first-wins.** The composition root passes roots as an ordered slice `[.ziki/skills, .kimi-code/skills, $HOME/.config/ziki/skills]` — local project overrides beat shared project skills, which beat user-global skills (spec FR-002); the registry loads each root's skills alphabetically (deterministic listing) and skips a name already registered. `source` records the root a skill came from for listings and diagnostics.
- **Skip-and-warn, never crash (FR-003)**: parse failures and unreadable files append a warning string to the registry; warnings surface in `/skill list` output and are otherwise inert. A root that does not exist is simply absent (edge case: fresh checkout).
- **Agent integration is two touches, both narrow** (ISP): (1) `GoalExecutor` gains `skills_listing: ?[]const u8`; when non-null, `systemPrompt()` appends a fixed header plus the listing lines; (2) the composition root registers `SkillTool` in the tools array **only when the registry is non-empty** (FR-010: zero skills ⇒ byte-identical behavior — no tool, no prompt change). `SkillTool.execute` parses `{"name": "..."}` (house JSON pattern), returns the verbatim body, or a clear `skill not found: <name>` error message listing available names (FR-006).
- **Shell integration follows the existing handler pattern**: `src/skill/handler.zig` exposes `runSkillCommand(alloc, registry, args) ![]const u8` returning the output text; `main.zig` wraps it in a `SkillCtx` + vtable handler registered as `"skill"` on the dispatcher (SC-005: dispatcher stays command-agnostic). `/skill` with no/unknown args prints usage (FR-008).
- **Memory**: registry and all strings live in per-invocation allocations owned by `main`/`runGoal` scopes, freed via `deinit` (house rule: bounded, explicit ownership; spec 008 discipline). Bodies are read once at load; nothing is re-read per turn.

## Files

| File | Responsibility |
|------|----------------|
| `src/skill/skill.zig` | `Skill` entity; frontmatter parser (pure); parser unit tests |
| `src/skill/registry.zig` | Roots-ordered discovery, dedup by name, warnings, `find`/`list`; registry unit tests (FakeFs) |
| `src/skill/tool.zig` | `SkillTool` (Tool vtable): fetch body by name; tool unit tests |
| `src/skill/handler.zig` | `/skill list` / `/skill show` text generation; handler unit tests |
| `src/fs/fs.zig` | `readDir` on `Fs`/`RealFs`/`FakeFs` (+ tests) |
| `src/agent/executor.zig` | `skills_listing` field + system-prompt section (+ tests) |
| `src/main.zig` | Composition: root resolution (`.ziki/skills` local, `.kimi-code/skills` shared, `~/.config/ziki/skills` user), registry load, tool/handler wiring, `/help` |
| `tests.zig` | Aggregator imports for `src/skill/*` |

## Verification Evidence

- `zig build test` green: all 23 pre-existing tests (no regressions, SC-004) plus the new suite covering FR-001…FR-011 one-for-one.
- Parser tests: valid, quoted, missing-name, missing-description, unterminated, no-frontmatter, name-over-dir-name (FR-001, FR-003).
- Registry tests: three-root precedence with duplicate names (FR-002, FR-004), malformed skip-and-warn (FR-003), absent/empty roots (edge), deterministic ordering.
- Tool tests: body-by-name (FR-006), unknown-name error message, malformed args (FR-006).
- Handler tests: `list` shows name/description/source (FR-007), `show` prints verbatim body, `show unknown` lists available skills, bare `/skill` and unknown subcommand print usage (FR-008).
- Executor test: system prompt contains the skills section and skill tool entry when a listing is provided; absent when null (FR-005, FR-010) — in-file test calling the prompt builder directly.
- Read-only guarantee (FR-009): the skill package writes nothing; verified by inspection + FakeFs test asserting the file map is unchanged after load.
