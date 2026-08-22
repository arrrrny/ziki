# Feature Specification: Tool Abstraction Layer

**Feature Branch**: `[003-tool-abstraction-layer]`

**Created**: 2026-08-22

**Status**: Draft

**Input**: User description: "Tool abstraction layer and core tools for the Zig Goal CLI. The agent needs capabilities equivalent to Kimi's to complete coding goals: read a file, edit a file (create/modify/delete regions), search file contents by pattern, and execute shell commands. All four capabilities MUST be exposed behind a single injectable Tool interface (Dependency Inversion per the constitution) so the agent loop and tests can use them without touching the filesystem or spawning processes directly. Each tool MUST return a structured result (success/failure, output, errors) rather than throwing or crashing. Must be independently testable: in tests, the tools run against a temporary working directory and (for command execution) a sandboxed process, and the Tool interface can be replaced with a fake to assert what the agent requested. Definition of done: the four tools work against a real temp directory and are each covered by tests that assert correct read output, correct edits, correct search matches, and correct command execution results, with no tool-specific logic embedded in the agent. This layer is a prerequisite for the autonomous goal execution feature."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Read a file's contents (Priority: P1)

The agent requests the contents of a file in the working directory. The tool returns the file's text (or an error if the file is missing or unreadable) as a structured result, without the agent touching the filesystem directly.

**Why this priority**: Reading is the most fundamental capability; the agent cannot plan or edit without first observing files.

**Independent Test**: Point the tool at a temporary directory containing a known file and assert the returned content matches the file exactly, and that a missing file yields a clear error result.

**Acceptance Scenarios**:

1. **Given** a file `a.txt` containing `hello`, **When** the read tool is invoked on `a.txt`, **Then** the result is success with content `hello`.
2. **Given** a path that does not exist, **When** the read tool is invoked, **Then** the result is failure with a clear "file not found" message and no crash.

---

### User Story 2 - Edit a file (Priority: P1)

The agent creates a new file or modifies/deletes a region of an existing file. The edit tool applies the change and returns a structured result describing what changed (or an error).

**Why this priority**: Editing is how the agent actually completes coding goals; it must be reliable and report failures instead of corrupting files.

**Independent Test**: In a temporary directory, create a file via the edit tool, then modify a line, then assert both the resulting file contents and the reported change are correct; also assert an edit to a nonexistent file (when creation is not requested) fails clearly.

**Acceptance Scenarios**:

1. **Given** an empty target path, **When** the edit tool is asked to create it with content `x`, **Then** the file exists with content `x` and the result reports success.
2. **Given** a file containing `old`, **When** the edit tool replaces `old` with `new`, **Then** the file contains `new` and the result reports success.
3. **Given** a malformed or conflicting edit (e.g. target region not found), **When** applied, **Then** the result is failure, the original file is unchanged, and no partial write occurs.

---

### User Story 3 - Search file contents by pattern (Priority: P1)

The agent searches the working directory (or a subtree) for text matching a pattern and gets back the matching locations/lines as a structured result.

**Why this priority**: Search lets the agent locate relevant code across many files without reading everything; essential for realistic goals.

**Independent Test**: Seed a temporary directory with files where a known substring appears in specific paths/lines, run the search tool, and assert the returned matches list exactly those locations.

**Acceptance Scenarios**:

1. **Given** files where `TODO` appears on line 3 of `b.txt`, **When** search for `TODO` is run, **Then** the result lists `b.txt:3` (and no false matches).
2. **Given** a pattern that matches nothing, **When** search is run, **Then** the result is success with an empty matches list (not an error).

---

### User Story 4 - Execute a shell command (Priority: P1)

The agent runs a shell command (e.g. build, test, lint) and receives its exit status and output as a structured result.

**Why this priority**: Running commands is how the agent verifies work (tests pass) and performs operations no single file tool covers.

**Independent Test**: Execute a command that prints known output and exits 0, assert the captured output and success status; execute a command that exits non-zero and assert the failure status and captured stderr are returned, never crashing the process.

**Acceptance Scenarios**:

1. **Given** a command `echo done`, **When** executed, **Then** the result is success with output containing `done`.
2. **Given** a command that exits with a non-zero status, **When** executed, **Then** the result is failure carrying the exit status and any output, and the agent process remains alive.

---

### User Story 5 - Use tools through an injected interface (Priority: P2)

The agent depends only on a Tool interface, not on concrete filesystem/process implementations. The same interface can be satisfied by a fake in tests so the agent's requests are asserted without side effects.

**Why this priority**: This is the constitution mandate (Dependency Inversion) and what makes the whole system testable; it is a shippable property on its own.

**Independent Test**: Register a fake Tool implementation, drive the agent (or a caller) through the interface, and assert the exact tool calls (name + arguments) the agent made, with no real filesystem or process touched.

**Acceptance Scenarios**:

1. **Given** a fake tool registered for `read`, **When** a caller invokes `read` through the interface, **Then** the fake records the call and returns its canned result, and no file is opened.
2. **Given** the concrete tools swapped for fakes at setup, **When** any tool is used, **Then** the dispatcher/agent code paths are unchanged, proving no tool-specific logic is embedded above the interface.

---

### Edge Cases

- File read of a binary or very large file: result must indicate size/type and not attempt to return unbounded content as text (configurable limit or error).
- Edit that would overwrite an existing file when only creation was intended: must fail rather than clobber.
- Edit with conflicting/duplicate old text: must report ambiguity rather than silently changing the wrong occurrence.
- Search with an invalid pattern: must return a clear error, not hang or crash.
- Command execution that times out or produces huge output: must be bounded (timeout + output cap) and return a structured result.
- Command execution attempting to escape the working directory: behavior must be defined (confined to working dir by default or explicitly allowed), never silently arbitrary.
- Tool invoked on a path outside the working directory: must be rejected or confined per a clearly stated rule.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST expose four tools — read file, edit file, search contents, execute command — each as a capability the agent can invoke.
- **FR-002**: System MUST expose all tools behind a single injectable Tool interface so callers depend on the interface, not on concrete implementations (Dependency Inversion).
- **FR-003**: Each tool MUST return a structured result indicating success or failure, plus output/errors, and MUST NOT crash or unwind the process on error.
- **FR-004**: The read tool MUST return the exact contents of an existing file and MUST return a clear failure when the file is missing or unreadable.
- **FR-005**: The edit tool MUST support creating a new file with given content and modifying an existing file by replacing a target region; it MUST report success or a clear failure.
- **FR-006**: The edit tool MUST leave the original file unchanged when an edit cannot be applied (target not found, ambiguous, or conflicting) and MUST NOT perform partial writes.
- **FR-007**: The search tool MUST return the locations/lines matching a pattern and MUST return an empty result set (success) when nothing matches.
- **FR-008**: The command tool MUST return the process exit status and captured output, MUST survive non-zero exits without crashing, and SHOULD be bounded by a timeout and output limit.
- **FR-009**: The Tool interface MUST be replaceable with a fake/test double so the agent's tool usage can be asserted without real filesystem or process side effects.
- **FR-010**: System MUST define and enforce a clear rule for paths/commands that fall outside the working directory (reject or confine), so tool use stays predictable and safe.

### Key Entities *(include if feature involves data)*

- **Tool**: A capability behind the injectable interface. Attributes: name, input parameters, structured result (status, output, errors).
- **Tool Result**: The outcome of a tool call. Attributes: status (success/failure), output payload, error detail, duration.
- **Working Directory**: The root the tools operate within; path/command confinement is enforced relative to it.
- **Tool Registry / Injector**: The component that supplies concrete tool implementations (or fakes) to the agent at setup.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: All four tools (read, edit, search, execute) operate correctly against a real temporary directory and are each covered by automated tests asserting correct output (100% of the tool set).
- **SC-002**: For every tool, error cases (missing file, unapplicable edit, no match, non-zero exit) return a structured failure result in 100% of test cases with no process crash.
- **SC-003**: The agent/caller depends solely on the Tool interface; a test swapping every tool for a fake asserts the exact tool calls made, with zero real filesystem/process access.
- **SC-004**: 100% of edge cases (oversized read, clobber prevention, ambiguous edit, invalid pattern, command timeout, out-of-dir path) are handled with defined, tested behavior.
- **SC-005**: No tool-specific logic exists above the Tool interface, verifiable by a test that runs the agent against fakes without modifying agent code.

## Assumptions

- **Interface-first (constitution)**: Per the project constitution (Dependency Inversion, SOLID), the agent MUST depend only on the Tool interface; concrete implementations are injected. This is non-negotiable.
- **Structured results, never exceptions**: Tools communicate success/failure via a result object, not by throwing/crashing, so the agent can branch on outcome deterministically.
- **Working-directory confinement**: By default tools operate within the session's working directory; out-of-dir access is rejected unless explicitly permitted. Exact policy is stated but the safety rule is fixed.
- **Command execution sandboxing**: Command execution in tests runs against a sandboxed/limited process; the spec requires bounded timeout and output, not a specific sandbox technology.
- **Edit model**: Edit supports full-file create and targeted region replace; finer operations (e.g. line-range, regex) are allowed as implementation detail but the create/replace contract is the testable minimum.
- **Language**: Implementation is in Zig per the overarching project constraint; this spec describes behavior, not code.
- **Scope boundary**: This feature delivers the tool layer only; the autonomous agent loop that orchestrates these tools is a separate later feature (goal execution).
