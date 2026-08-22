# Tasks: Zig Goal CLI (ziki)

**Input**: Design documents from `/specs/001-zig-goal-cli/`

**Prerequisites**: plan.md (required), spec.md (required for user stories), research.md, data-model.md, contracts/

**Tests**: REQUIRED. The constitution (Principle V) mandates TDD: every behavior
has a test written first, watched to fail (RED), then implemented to pass (GREEN).
Test tasks are paired with their implementation tasks below.

**Organization**: Tasks grouped by user story. MVP = User Story 1 (the goal
loop). Providers (US3), Resume (US4), and Memory discipline (US2) follow so the
result is a genuinely usable, running `ziki` binary.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (US1..US4)
- Exact file paths included in descriptions

## Phase 1: Setup (Shared Infrastructure)

- [ ] T001 Create project directory structure per plan.md: `build.zig`, `src/{cli,agent,provider,tool,goal,fs,config}/`, `.gitignore`
- [ ] T002 [P] Write `build.zig` with an `exe` step (`ziki`) and a `test` step aggregating all `_test.zig`
- [ ] T003 [P] Add `.gitignore` entries (`zig-out/`, `.ziki/`)

---

## Phase 2: Foundational (Blocking Prerequisites — interfaces, types, DI boundaries)

**⚠️ No user story work begins until this phase is complete.**

- [ ] T004 [P] Define `Goal` value type + `Budgets` in `src/goal/goal.zig` (data-model.md) with `src/goal/goal_test.zig`
- [ ] T005 [P] Define `Provider` interface (vtable) + `ChatMessage`/`ToolCall`/`ChatResponse` types in `src/provider/provider.zig` with `src/provider/provider_test.zig`
- [ ] T006 [P] Define `Tool` interface + `ToolResult` + `ToolSpec` in `src/tool/tool.zig` with `src/tool/tool_test.zig`
- [ ] T007 [P] Define `Transport` interface in `src/provider/transport.zig` + `HttpTransport` over `std.http.Client`/`std.crypto.tls` with `src/provider/transport_test.zig` (fake transport)
- [ ] T008 [P] Define `Fs` interface + `RealFs` + `FakeFs` in `src/fs/fs.zig` with `src/fs/fs_test.zig` (DIP boundary for tools/repo)
- [ ] T009 Define `Config` loading (provider name, model, endpoint, api_key; 5 valid names) in `src/config/config.zig` with `src/config/config_test.zig`
- [ ] T010 [P] Define `GoalRepository` interface + `FsGoalRepository` (JSON via std.json) in `src/goal/repository.zig` with `src/goal/repository_test.zig`

**Checkpoint**: All interfaces, types, and DI boundaries exist and their unit tests pass. User stories may begin.

---

## Phase 3: User Story 1 - Define and complete a goal autonomously (Priority: P1) 🎯 MVP

**Goal**: User runs `/goal <objective>`, the agent pursues it autonomously across
turns using a provider + coding tools, and reports completion (FR-001..FR-003,
FR-007, FR-008, FR-010).

**Independent Test**: `zig build test` — `agent/executor_test.zig` drives
`GoalExecutor` with `FakeProvider` + real `read`/`edit`/`bash` tools against a
temp dir and asserts the goal reaches `completed` and produces the expected file
(quickstart Scenario B). Manual: `zig build run -- /goal "..."` with a real or
fake provider completes the goal and prints `status: completed` (Scenario C).

### Tests for User Story 1 (write FIRST, ensure they FAIL) ⚠️

- [ ] T011 [US1] Write failing test: `FakeProvider` returns scripted `ChatResponse` sequences in `src/provider/fake.zig` + `src/provider/fake_test.zig`
- [ ] T013 [US1] Write failing test: `GoalExecutor` runs a full loop (FakeProvider + real tools) to `completed`, creating an artifact, in `src/agent/executor_test.zig`
- [ ] T015 [US1] Write failing test: `OpenAIProvider` issues a Chat Completions request via `Transport` and parses a `ChatResponse` in `src/provider/openai_test.zig` (fake transport)
- [ ] T017 [US1] Write failing tests for tools: `ReadTool`/`EditTool`/`SearchTool`/`BashTool` in `src/tool/{read,edit,search,bash}_test.zig` (use `FakeFs` where I/O)
- [ ] T018 [US1] Write failing test: CLI parser parses `/goal`, `/stop`, `/provider`, `/status`; rejects empty/malformed and no-provider with `error:` lines in `src/cli/cli_test.zig`

### Implementation for User Story 1

- [ ] T012 [US1] Implement `FakeProvider` in `src/provider/fake.zig` (satisfies `Provider` vtable; deterministic scripted responses)
- [ ] T014 [US1] Implement `GoalExecutor` loop in `src/agent/executor.zig`: assemble messages + tool schemas, call `provider.complete`, execute `tool_calls` via `Tool`, evaluate completion/criterion, enforce budgets (turns/tokens/time), persist via `GoalRepository` each turn, honor `/stop` (FR-002/003/008)
- [ ] T016 [US1] Implement `OpenAIProvider` (OpenAI-compatible Chat Completions over `Transport`) in `src/provider/openai.zig` (reference provider, spec 004)
- [ ] T017b [US1] Implement `ReadTool`, `EditTool`, `SearchTool`, `BashTool` in `src/tool/{read,edit,search,bash}.zig` over injected `Fs` (FR-007 tool parity)
- [ ] T019 [US1] Implement CLI parser/dispatcher `src/cli/cli.zig` (FR-001, FR-008, FR-010 error contract from contracts/cli-commands.md)
- [ ] T020 [US1] Implement composition root `src/main.zig`: load `Config`, select provider (preset or `FakeProvider` when env-gated), wire tools (`RealFs`), `FsGoalRepository`, `GoalExecutor`, run REPL printing status/summary per contract
- [ ] T021 [US1] Add integration test wiring the full binary path (executor e2e verified without network) — reference quickstart Scenario B

**Checkpoint**: User Story 1 independently functional — `/goal` completes end-to-end (FakeProvider-backed test green; real provider path builds). This is the shippable MVP.

---

## Phase 4: User Story 3 - Connect to the required providers (Priority: P3)

**Goal**: All five required providers (opencode, kilo, z.ai, kimi, OpenAI-compatible
custom) usable; everything else dropped (FR-004, FR-005).

**Independent Test**: `provider/presets_test.zig` builds all five presets, each
satisfies `Provider` (LSP), and an unknown name errors. `config_test.zig` accepts
the five names + per-session override.

### Tests for User Story 3 ⚠️

- [ ] T022 [US3] Write failing test: presets build 5 `Provider`s (opencode/kilo/zai/kimi/openai_custom), all interchangeable, unknown name errors — `src/provider/presets_test.zig`

### Implementation for User Story 3

- [ ] T023 [US3] Implement `provider/presets.zig`: 5 config-driven `OpenAIProvider` instances (no branching, OCP); one client, five presets (FR-004)
- [ ] T024 [US3] Extend `src/config/config.zig` to accept the five provider names + per-session override (FR-005); extend `config_test.zig`

**Checkpoint**: All five providers constructible and selectable; the four extra
presets (slice 007) verifiable against live endpoints by the user.

---

## Phase 5: User Story 4 - Resume a goal across restarts (Priority: P4)

**Goal**: Active goal state survives a process restart and resumes without
re-definition (FR-006, SC-004); windows stay isolated (spec edge case).

**Independent Test**: `repository_test.zig` + `executor_test.zig` — load an
active saved goal, executor resumes the loop (no re-prompt); a completed goal is
reported completed; two sessions use distinct state files.

### Tests for User Story 4 ⚠️

- [ ] T025 [US4] Write failing test: `GoalRepository.load` returns active goal; executor resumes loop from saved progress; completed goal reported; per-session isolation — `src/goal/repository_test.zig` / `src/agent/executor_test.zig`

### Implementation for User Story 4

- [ ] T026 [US4] Implement resume: `main.zig` loads existing active goal before the loop; executor continues rather than re-prompting; isolation via `session_id` + per-session `goal.<session_id>.json` (FR-006, SC-004)

**Checkpoint**: Restart resumes the same goal with no re-definition and no cross-window corruption.

---

## Phase 6: User Story 2 - Many windows, tiny memory (Priority: P2)

**Goal**: Bounded per-window memory so 20 windows stay far below the 10 GB
baseline (FR-009, SC-002). Formal 20-window measurement is slice 008; here we
enforce the discipline the measurement checks.

**Independent Test**: Executor uses per-turn arena reset + bounded history; a
memory-budget test (slice 008) spawns N windows and asserts RSS <= threshold.

### Tests for User Story 2 ⚠️

- [ ] T027 [US2] Write failing test: message history is compacted/bounded when it exceeds the token cap; per-turn allocator is reset (no growth across turns) — `src/agent/executor_test.zig`

### Implementation for User Story 2

- [ ] T028 [US2] Implement per-turn arena reset + bounded message history with compaction in `src/agent/executor.zig` (FR-009, spec context edge case)
- [ ] T029 [US2] Add memory-budget harness/test scaffolding (slice 008): spawn N `ziki` subprocesses, measure RSS, assert <= threshold (SC-002)

**Checkpoint**: Memory discipline in place; formal budget gate lives in slice 008.

---

## Phase 7: Polish & Cross-Cutting Concerns

- [ ] T030 [P] Run full `zig build test` suite — all green (constitution shippable gate)
- [ ] T031 Run quickstart.md validation Scenarios A–E (F is env-gated) end-to-end on the built binary
- [ ] T032 Final self-audit against constitution: SOLID / DRY / Open-Closed / TDD compliance on every module

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — start immediately
- **Foundational (Phase 2)**: Blocks all user stories
- **US1 (Phase 3)**: Depends on Foundational — delivers MVP
- **US3 (Phase 4)**: Depends on Foundational + US1 provider path
- **US4 (Phase 5)**: Depends on US1 (repository exists)
- **US2 (Phase 6)**: Depends on US1 (executor exists)
- **Polish (Phase 7)**: Depends on all stories

### User Story Dependencies

- **US1 (P1)**: After Foundational. No dependency on other stories.
- **US3 (P3)**: After Foundational + US1; uses the OpenAIProvider from US1.
- **US4 (P4)**: After US1; extends persistence with resume.
- **US2 (P2)**: After US1; adds memory discipline to the executor.

### Parallel Opportunities

- All Phase 1 + Phase 2 `[P]` tasks run in parallel (independent files).
- Within US1, T011/T013/T015/T017/T018 tests are parallel; their impls follow.
- US3/US4/US2 can proceed sequentially after US1 (single-developer order here).

---

## Parallel Example: User Story 1

```bash
# Write the failing tests together (TDD RED):
Task T011: FakeProvider scripted responses (src/provider/fake_test.zig)
Task T013: Executor full-loop e2e (src/agent/executor_test.zig)
Task T015: OpenAIProvider request/parse (src/provider/openai_test.zig)
Task T017: Tool tests (src/tool/{read,edit,search,bash}_test.zig)
Task T018: CLI parser tests (src/cli/cli_test.zig)

# Then implement to green (GREEN):
Task T012: FakeProvider  -> T014: GoalExecutor -> T016: OpenAIProvider
Task T017b: tools -> T019: cli -> T020: main
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Phase 1 + Phase 2 (foundation: interfaces + DI boundaries).
2. Phase 3 (US1): TDD the executor loop with `FakeProvider` + real tools.
3. **STOP and VALIDATE**: `zig build test` green; Scenario B passes -> first running shippable `ziki`.

### Incremental Delivery

1. Setup + Foundational -> foundation ready.
2. US1 -> test independently -> **first running shippable ziki** (MVP!).
3. US3 (5 providers) -> test independently.
4. US4 (resume) -> test independently.
5. US2 (memory discipline) -> test independently.
6. Polish -> full suite + quickstart validation.

---

## Notes

- Tests are REQUIRED and written first (constitution Principle V). Verify RED before GREEN.
- Follow SOLID / DIP / Open-Closed: new behavior = new code behind interfaces (no branching on provider/tool kind).
- Commit after each task or logical group; stop at each Checkpoint to validate independently.
- Slice 008 (formal 20-window memory budget) and slice 007 (live provider verification) extend this plan; their scaffolding is included (T029 / T023-T024).
