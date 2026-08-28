# Tasks: Skill System — Load and Run Skills Like a Coding Editor

**Input**: Design documents from `/specs/009-skill-system/`
**Prerequisites**: `spec.md`, `plan.md`

**Tests**: Required — the constitution (TDD, Principle V) mandates tests FIRST. Every implementation task below pairs with its test task in the same unit (in-file `test` blocks, house pattern) or is itself a test-only task.

**Organization**: Tasks grouped by phase and user story (US1–US3 from spec.md). `zig` on the box: `export PATH=/workspace/herdr/.cache/zig/zig-x86_64-linux-0.15.2:$PATH`.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)

## Phase 1: Foundations (no cross-dependencies)

- [X] T001 [P] Extend the `Fs` boundary with `readDir` (direct entry names): add the
  vtable operation to `Fs` (`src/fs/fs.zig`), implement `RealFs.readDir` via
  `std.fs` iteration and `FakeFs.readDir` by synthesizing direct children from the
  flat path map; in-file tests for both (FR-002 groundwork, plan §Architecture).
- [X] T002 [P] Create `src/skill/skill.zig`: `Skill` entity (name, description,
  body, source) + pure frontmatter parser (strict `---` open/close, required
  name/description, optional quote stripping, frontmatter name authoritative);
  write parser tests FIRST covering valid, quoted, missing-name,
  missing-description, unterminated, no-frontmatter (FR-001, FR-003).

## Phase 2: User Story 3 — Discovery & precedence (P2, but foundation for US1/US2)

- [X] T003 [P] [US3] Create `src/skill/registry.zig`: `SkillRegistry.load(alloc, fs,
  roots)` with roots-ordered first-wins dedup, alphabetical order within a root,
  skip-and-warn on parse/read failure, `find(name)`, `list()`, `warnings()`,
  `deinit`; write FakeFs tests FIRST: three-root precedence with duplicate names,
  malformed-skill skip (warning recorded, others load), absent/empty roots,
  deterministic listing order, read-only (file map unchanged) (FR-002, FR-003,
  FR-004, FR-009).

## Phase 3: User Story 1 — Agent integration (P1)

- [X] T004 [P] [US1] Create `src/skill/tool.zig`: `SkillTool` (Tool vtable, name
  `skill`, schema `{"name": string}`) returning the verbatim body, or a clear
  `skill not found: <name>` error listing available names; malformed JSON args →
  error result, never a crash; write tool tests FIRST (FR-006).
- [X] T005 [US1] Extend `src/agent/executor.zig`: optional `skills_listing:
  ?[]const u8` field; `systemPrompt()` appends the skills section (fixed header +
  listing) only when non-null; write the prompt-builder test FIRST asserting the
  section appears with a listing and the prompt is byte-identical when null
  (FR-005, FR-010).
- [X] T006 [US1] Wire the agent path in `src/main.zig` `runGoal`: resolve roots
  (`.ziki/skills`, `.kimi-code/skills` relative to cwd; `$HOME/.config/ziki/skills`
  absolute), load the registry, register `SkillTool` in the tools array and pass
  the listing to the executor ONLY when the registry is non-empty (zero skills ⇒
  behavior identical to pre-feature) (FR-002, FR-005, FR-006, FR-010).

## Phase 4: User Story 2 — Shell commands (P1)

- [X] T007 [P] [US2] Create `src/skill/handler.zig`: `runSkillCommand(alloc,
  registry, args) ![]const u8` producing `/skill list` (name, description, source,
  plus warnings), `/skill show <name>` (verbatim body), `skill not found`
  message listing available skills, and usage text for bare `/skill`, missing
  show argument, or unknown subcommand; write handler tests FIRST (FR-007,
  FR-008).
- [X] T008 [US2] Register the `skill` handler on the dispatcher in `src/main.zig`
  (SkillCtx + vtable, house pattern), register the shared registry used by both
  `/skill` and `/goal`, and add the `/skill` line to `/help` output (FR-007).

## Phase 5: Verification & docs

- [X] T009 Add `src/skill/*` imports to the `tests.zig` aggregator; run
  `zig build test` — all pre-existing tests (23) plus the new suite must pass
  with zero regressions (FR-011, SC-003, SC-004).
- [X] T010 [US2] Document the skill system in `README.md`: skills directory
  conventions, precedence, `/skill` commands, and the agent-facing skill tool
  (one compact section, house tone).

## Definition of Done

- Every FR-001…FR-011 has at least one passing test (SC-004).
- `zig build test` fully green on the box toolchain (SC-004).
- Manual smoke on the box: `/skill list` and `/skill show` against a fixture
  skills tree; `/goal` unchanged with zero skills (SC-001, SC-002).
