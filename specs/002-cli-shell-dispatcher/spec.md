# Feature Specification: CLI Shell Dispatcher

**Feature Branch**: `[002-cli-shell-dispatcher]`

**Created**: 2026-08-22

**Status**: Draft

**Input**: User description: "Interactive CLI shell and slash-command dispatcher for the Zig Goal CLI. A terminal REPL that reads input line-by-line, tokenizes and parses slash commands (/goal, /stop, /provider, /goals, /help) into structured command intents, and dispatches each intent to a registered handler via an injectable command-handler interface. Must be independently testable: given a raw input line it returns the parsed intent without performing side effects, and it must accept scripted/non-interactive input so the parser and dispatch can be unit-tested in isolation. Per the project constitution, parsing and dispatch MUST depend on injected handler interfaces (Dependency Inversion) so handlers are unit-testable without a live agent. Definition of done: a runnable REPL that correctly parses the documented commands and routes them to the right handler, verified by tests that feed input lines and assert the resulting intents and dispatch calls. This is the foundational layer that every later feature (goal execution, providers, tools) plugs into."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Parse a slash command into a structured intent (Priority: P1)

A developer types a slash command such as `/goal add a login function` into the terminal. The shell reads the line, recognizes it as a command, parses the command name and its arguments, and produces a structured intent object that a handler can act on. This works without executing any side effects, so it can be tested in isolation.

**Why this priority**: Every other feature (goal execution, provider switching, stopping a goal) is just a handler wired into this dispatcher. Without reliable parsing and routing, no command works.

**Independent Test**: Feed a set of raw input lines (e.g. `/goal ...`, `/stop`, `/provider openai`, `/goals`, `/help`) into the parser and assert the exact command name, arguments, and normalized intent returned for each. No agent, provider, or filesystem side effects occur.

**Acceptance Scenarios**:

1. **Given** the input line `/goal add a parser to the project`, **When** it is parsed, **Then** the resulting intent has command `goal` and argument text `add a parser to the project`.
2. **Given** the input line `/provider openai`, **When** it is parsed, **Then** the resulting intent has command `provider` and argument `openai`.
3. **Given** the input line `/help`, **When** it is parsed, **Then** the resulting intent has command `help` and no arguments.

---

### User Story 2 - Dispatch the intent to the correct handler (Priority: P1)

Once an intent is produced, the dispatcher routes it to the handler registered for that command. Handlers are supplied from the outside (injected), so the dispatcher itself contains no command behavior.

**Why this priority**: Routing correctness is what makes commands actually do something. It must be verifiable without running a real agent.

**Independent Test**: Register fake handlers for each command, dispatch a parsed intent for `goal`, and assert that exactly the `goal` handler was invoked with that intent, and that no other handler ran.

**Acceptance Scenarios**:

1. **Given** handlers are registered for `goal`, `stop`, `provider`, `goals`, and `help`, **When** an intent for `stop` is dispatched, **Then** only the `stop` handler is called with that intent.
2. **Given** no handler is registered for a command, **When** an intent for that command is dispatched, **Then** a clear "unknown command" result is produced and no handler crashes the process.

---

### User Story 3 - Run as an interactive REPL and from scripted input (Priority: P2)

The shell runs as a terminal loop that reads one line at a time, parses, dispatches, prints the handler's result, and repeats until the user exits. The same engine must also accept a stream of pre-supplied lines (scripted/non-interactive) so it can be driven and asserted in automated tests and pipelines.

**Why this priority**: The REPL is the product surface; scripted input is what makes the whole thing testable and automatable, satisfying the project's test-first mandate.

**Independent Test**: Drive the engine with a scripted list of lines (`/help`, `/provider kimi`, `/stop`) and assert the sequence of dispatched intents and printed outputs matches, without requiring a human at the keyboard.

**Acceptance Scenarios**:

1. **Given** scripted input lines, **When** the engine runs, **Then** each line is parsed and dispatched in order and the loop ends when input is exhausted.
2. **Given** interactive mode, **When** the user types a line and presses enter, **Then** the result is printed and the prompt returns for the next line.
3. **Given** an explicit exit command or end-of-input, **When** reached, **Then** the loop terminates cleanly.

---

### Edge Cases

- Empty or whitespace-only line: ignored (no dispatch) or treated as a no-op, not an error.
- Unknown command: reported clearly as unknown, no crash.
- Malformed command (e.g. `/` with no name, or a name with invalid characters): rejected with guidance.
- Command with missing required argument (e.g. `/provider` with no value): rejected with a clear message stating what is missing.
- Plain natural-language text with no leading slash: treated as a non-command message (routed to a default handler or ignored per configuration), not parsed as a slash command.
- Duplicate registration of the same command: rejected at setup time so dispatch stays unambiguous.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST read user input line-by-line from an input source that is interchangeable (interactive terminal or scripted stream).
- **FR-002**: System MUST recognize a line beginning with `/` as a slash command and parse it into a command name plus argument text.
- **FR-003**: System MUST tokenize and normalize the parsed input into a structured intent containing at least the command name and its arguments.
- **FR-004**: System MUST support the commands `goal`, `stop`, `provider`, `goals`, and `help` as the initial command set.
- **FR-005**: System MUST dispatch each parsed intent to the handler registered for its command via an injected handler interface (no command logic embedded in the dispatcher).
- **FR-006**: System MUST allow handlers to be registered and resolved by command name from the outside (Dependency Inversion); the dispatcher MUST NOT hard-code behavior for any command.
- **FR-007**: System MUST print a handler's result back to the output sink and continue the loop until an exit condition is met.
- **FR-008**: System MUST report an unknown command without crashing and without invoking any handler.
- **FR-009**: System MUST reject a malformed command or a command missing a required argument with a clear, actionable message.
- **FR-010**: System MUST treat input that does not begin with `/` as a non-command message and route it via a configurable default path rather than failing to parse.

### Key Entities *(include if feature involves data)*

- **Command Intent**: The parsed result of a slash command. Attributes: command name, argument text, raw source line, parse timestamp.
- **Command Handler**: A unit that receives an intent and produces a result. Defined behind an interface so it can be supplied/injected and tested in isolation.
- **Dispatcher**: The routing component that maps a command name to its registered handler and invokes it. Depends only on the handler interface.
- **Input/Output Source**: The stream the shell reads lines from and writes results to; must be swappable so tests use scripted input and captured output.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: For 100% of the documented command set (goal, stop, provider, goals, help), a representative input line is parsed into the correct command name and arguments, verified by automated tests.
- **SC-002**: For 100% of dispatched intents in tests, the correct registered handler is invoked and no unrelated handler runs.
- **SC-003**: The engine processes a scripted sequence of at least 10 input lines and produces the expected ordered intents and outputs without human interaction.
- **SC-004**: Malformed input, unknown commands, and missing arguments are each handled with a clear message in 100% of test cases, with no process crash.
- **SC-005**: The dispatcher contains zero command-specific behavior; all command logic lives behind injected handlers, confirmable by a test that swaps every handler without changing the dispatcher.

## Assumptions

- **Command set is initial, not final**: The five commands listed are the starting set; later features (goal execution, providers, tools) register their own handlers against this same dispatcher. The dispatcher must not assume a fixed list.
- **Interface-first per constitution**: Per the project constitution (Dependency Inversion, SOLID), the dispatcher depends only on a handler interface; concrete handlers (including the future goal/provider handlers) are injected at setup. This is a hard requirement, not a suggestion.
- **Non-command text**: Lines without a leading `/` are out of scope for slash parsing and are routed via a configurable default (e.g., to a future chat/default handler). This feature only guarantees they are not mis-parsed as commands.
- **Output format**: The exact textual format of help/errors is not specified and is explicitly not important (cosmetics out of scope); what matters is that results are returned to the output sink and are machine-assertable in tests.
- **Provider/goal semantics**: The actual behavior of `/goal` and `/provider` is defined by later features; this feature only guarantees correct parsing and routing to whatever handler is registered.
- **Language**: Implementation is in Zig per the overarching project constraint; this spec describes behavior, not code.
