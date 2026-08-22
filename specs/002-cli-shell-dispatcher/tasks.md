# Tasks: CLI Shell Dispatcher

**Input**: Design documents from `/specs/002-cli-shell-dispatcher/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/cli-commands.md

**Tests**: REQUIRED — the project constitution (Principle V) and the user mandate
TDD, so every user story writes tests FIRST (RED), then implements to make them
pass (GREEN). Test tasks are marked and must fail before their implementation.

**Organization**: Tasks grouped by user story so each story is independently
implementable and testable.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (US1, US2, US3)
- Exact file paths included

## Phase 1: Setup (Shared Infrastructure)

- [ ] T001 Create the `src/shell/` module and register `src/shell/shell_test.zig` in `tests.zig` so `zig build test` executes the shell test suite

---

## Phase 2: Foundational (Blocking Prerequisites)

**⚠️ CRITICAL**: No user story work can begin until these types/interfaces exist.

- [ ] T002 [P] Define `Intent` and `Result` types in `src/shell/intent.zig` (fields per data-model.md: command, args, raw / output, exit)
- [ ] T003 [P] Define the `Handler` vtable interface (`ctx` + `VTable.handle(alloc, intent) !Result`) in `src/shell/handler.zig`

**Checkpoint**: Core types and the handler boundary exist — user stories can begin.

---

## Phase 3: User Story 1 - Parse a slash command into a structured intent (Priority: P1) 🎯 MVP

**Goal**: Turn a raw line into an `Intent` (command + args) with no side effects.

**Independent Test**: Feed `/goal ...`, `/stop`, `/provider openai`, `/goals`,
`/help` and assert exact command + args; feed empty/whitespace, non-slash, and
malformed lines and assert the correct no-op / `""` / error outcome. No agent,
provider, or filesystem involved.

### Tests for User Story 1 (WRITE FIRST — must FAIL before implementation)

- [ ] T004 [P] [US1] Test (RED) `parseLine` in `src/shell/shell_test.zig`: slash commands parse to correct command+args; empty/whitespace → null; non-slash → `Intent{ command = "", args = text }`; `/` with no name or invalid chars → parse error

### Implementation for User Story 1

- [ ] T005 [US1] Implement `parseLine` in `src/shell/parser.zig` to satisfy T004 (split command + trimmed remainder; no command-specific logic)

**Checkpoint**: US1 fully functional and testable on its own.

---

## Phase 4: User Story 2 - Dispatch the intent to the correct handler (Priority: P1) 🎯 MVP

**Goal**: Route each `Intent` to the registered handler via the injected
interface; dispatcher contains zero command logic.

**Independent Test**: Register fake handlers for goal/stop/provider/goals/help,
dispatch a `stop` intent, assert ONLY the stop handler ran; dispatch an unknown
command, assert no handler ran and a clear "unknown command" result returned;
attempt duplicate registration, assert it is rejected.

### Tests for User Story 2 (WRITE FIRST — must FAIL before implementation)

- [ ] T006 [P] [US2] Test (RED) `Dispatcher` in `src/shell/shell_test.zig`: only the matching handler is invoked; unknown command invokes none + returns clear result; duplicate `register` is rejected; `command = ""` routes to `default_handler` when set

### Implementation for User Story 2

- [ ] T007 [US2] Implement `Dispatcher` (`register` + `dispatch` + optional `default_handler`) in `src/shell/dispatcher.zig` to satisfy T006

**Checkpoint**: US1 + US2 (the core dispatcher) fully functional and testable.

---

## Phase 5: User Story 3 - Interactive REPL and scripted input (Priority: P2)

**Goal**: A loop that reads lines from an injected source, parses, dispatches,
prints the `Result`, and repeats until exit/EOF. Same engine driven by scripted
input for tests.

**Independent Test**: Drive the engine with a scripted list (`/help`,
`/provider kimi`, `/stop`) and assert the ordered dispatched intents + printed
outputs, loop ends on input exhaustion, no human required.

### Tests for User Story 3 (WRITE FIRST — must FAIL before implementation)

- [ ] T008 [P] [US3] Test (RED) REPL in `src/shell/shell_test.zig`: scripted input produces expected ordered intents + outputs and terminates on EOF; empty line is ignored; `Result.exit` stops the loop

### Implementation for User Story 3

- [ ] T009 [US3] Implement the REPL loop over an injected line reader + output sink in `src/shell/repl.zig`
- [ ] T010 [US3] Refactor `src/main.zig` into the composition root: build `Dispatcher`, register `goal`/`stop`/`provider`/`goals`/`help` handlers (adapt existing logic; add minimal `help` + `goals` handlers), and run the REPL via `src/shell`

**Checkpoint**: Full feature shippable — REPL runs interactively and is
scriptable; all five commands route correctly.

---

## Phase 6: Polish & Cross-Cutting Concerns

- [ ] T011 [P] Run `specs/002-cli-shell-dispatcher/quickstart.md` validation (`zig build test` green; scripted REPL example)
- [ ] T012 [P] Add edge-case unit tests (malformed message text, missing-arg command) to `src/shell/shell_test.zig` per contracts/cli-commands.md

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (T001)**: no deps — start immediately
- **Foundational (T002, T003)**: block all user stories
- **US1 (T004→T005)**: after Foundational
- **US2 (T006→T007)**: after Foundational; independent of US1 but pairs with it for the MVP
- **US3 (T008→T009→T010)**: after US1 + US2
- **Polish (T011, T012)**: after all stories

### Within Each User Story

- Tests (T004, T006, T008) written and FAILING before implementation
- Implement (T005, T007, T009) to turn tests green
- Story complete before next priority

### Parallel Opportunities

- T002 and T003 are independent files → parallel
- T004 / T006 / T008 test tasks are independent files → parallel
- US1 and US2 are independently testable increments

---

## Implementation Strategy

### MVP First (US1 + US2)

1. T001 setup → T002/T003 foundational
2. T004 (RED) → T005 (GREEN): parsing works
3. T006 (RED) → T007 (GREEN): dispatch works
4. **STOP and VALIDATE**: `zig build test` — parser + dispatcher proven in isolation
5. MVP (parse + route) shippable

### Incremental Delivery

1. MVP (US1+US2) → tested
2. US3 (REPL) → tested → full feature
3. Polish → quickstart validation

---

## Notes

- Every test task must FAIL before its implementation task runs.
- The dispatcher never inspects `command` to choose behavior (SC-005); all
  command logic lives behind registered handlers.
- `main.zig` becomes the composition root only; no command logic remains inline.
