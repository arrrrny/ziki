# Feature Specification: Provider Integrations (opencode, kilo, z.ai, kimi)

**Feature Branch**: `[007-provider-integrations-four]`

**Created**: 2026-08-22

**Status**: Draft

**Input**: User description: "Provider integrations: opencode, kilo, z.ai, kimi for the Zig Goal CLI. The master spec requires exactly five providers; feature 004 delivered the Provider interface plus the OpenAI-compatible reference. This feature delivers the remaining four named providers — opencode, kilo, z.ai, and kimi — each implemented behind the SAME injectable Provider interface (Dependency Inversion per the constitution) so they are interchangeable with the reference and with each other. Each provider MUST be independently configurable (endpoint/credential/model as applicable) and independently testable: in tests it is exercised against a mock/recorded endpoint (or a fake) asserting the exact request it sends and how it parses that provider's response shape, including tool calls, with no live account. Definition of done: each of the four providers correctly sends a request and parses a response against a mock endpoint, and each can be swapped in to drive a scripted goal to completion through the execution loop (feature 006). This closes the master spec's provider requirement (FR-004, SC-003) for all five backends."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Use opencode as the goal backend (Priority: P1)

The user configures the opencode provider (endpoint/credential/model as applicable) and the agent drives goals through it exactly as through the reference provider, because both satisfy the same interface.

**Why this priority**: opencode is one of the five required backends; without it the provider set is incomplete.

**Independent Test**: Exercise the opencode provider against a mock endpoint, assert the exact request it sends and that a mocked tool-call response is parsed correctly; then swap it into the execution loop (feature 006) with fakes for tools and assert a scripted goal completes.

**Acceptance Scenarios**:

1. **Given** a configured opencode provider and a mock endpoint, **When** a completion is requested, **Then** the request matches opencode's expected shape and the parsed completion (including tool calls) is correct.
2. **Given** the opencode provider wired into the execution loop, **When** a scripted goal runs, **Then** the goal reaches `completed` through opencode.

---

### User Story 2 - Use kilo as the goal backend (Priority: P1)

Same as opencode but for the kilo provider: independently configurable and testable, interchangeable via the shared interface.

**Why this priority**: kilo is one of the five required backends.

**Independent Test**: Mock-endpoint test for request shape + response/tool-call parsing, plus a swap-in execution-loop completion test.

**Acceptance Scenarios**:

1. **Given** a configured kilo provider and a mock endpoint, **When** a completion is requested, **Then** the request matches kilo's expected shape and tool calls parse correctly.
2. **Given** the kilo provider wired into the execution loop, **When** a scripted goal runs, **Then** the goal completes through kilo.

---

### User Story 3 - Use z.ai as the goal backend (Priority: P1)

Same pattern for the z.ai provider: independently configurable and testable, interchangeable via the shared interface.

**Why this priority**: z.ai is one of the five required backends.

**Independent Test**: Mock-endpoint test for request shape + response/tool-call parsing, plus a swap-in execution-loop completion test.

**Acceptance Scenarios**:

1. **Given** a configured z.ai provider and a mock endpoint, **When** a completion is requested, **Then** the request matches z.ai's expected shape and tool calls parse correctly.
2. **Given** the z.ai provider wired into the execution loop, **When** a scripted goal runs, **Then** the goal completes through z.ai.

---

### User Story 4 - Use kimi as the goal backend (Priority: P1)

Same pattern for the kimi provider: independently configurable and testable, interchangeable via the shared interface.

**Why this priority**: kimi is the user's primary backend and one of the five required; it must be a first-class option.

**Independent Test**: Mock-endpoint test for request shape + response/tool-call parsing, plus a swap-in execution-loop completion test.

**Acceptance Scenarios**:

1. **Given** a configured kimi provider and a mock endpoint, **When** a completion is requested, **Then** the request matches kimi's expected shape and tool calls parse correctly.
2. **Given** the kimi provider wired into the execution loop, **When** a scripted goal runs, **Then** the goal completes through kimi.

---

### User Story 5 - Switch providers without changing the agent (Priority: P2)

Because all five providers satisfy the same interface, the active provider is selected by configuration and the agent/loop code is untouched when moving between them.

**Why this priority**: This is the constitution's Dependency Inversion payoff and what lets the user pick their backend per session; it is a shippable property.

**Independent Test**: Build the agent/loop with each of the four providers (and the reference) in turn via configuration and assert identical behavior driving the same scripted goal.

**Acceptance Scenarios**:

1. **Given** the same scripted goal and the same loop, **When** each of the five providers is selected in turn, **Then** the goal completes identically in every case.
2. **Given** a provider selected per session vs globally, **When** configured, **Then** the selected provider is the one used, and switching does not alter agent code.

---

### Edge Cases

- Provider returns a response shape that differs from the reference (e.g. tool calls nested differently): each provider MUST parse its own shape correctly, not assume the reference shape.
- Missing/invalid configuration for a specific provider: clear configuration error before any request (per feature 004 behavior).
- Network failure / non-200 / malformed response: each provider returns a structured error (per feature 004), never crashes.
- Unknown tool name in a provider's response: surfaced as a clear error (per feature 004 / 006), not executed.
- A provider's credential model differs (some need a key, some a token, some none): configuration MUST accommodate each without forcing the others' fields.
- Response without text and without a valid tool call: treated as a defined error/no-op per feature 004.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST implement four providers — opencode, kilo, z.ai, kimi — each behind the SAME injectable Provider interface defined in feature 004 (Dependency Inversion).
- **FR-002**: Each of the four providers MUST be independently configurable with the fields it requires (endpoint, credential/model as applicable), without forcing the other providers' configuration shape.
- **FR-003**: Each provider MUST send a request matching its own expected request shape and MUST parse its own response shape, including tool calls, correctly.
- **FR-004**: Each provider MUST be testable against a mock/recorded endpoint asserting the exact request sent and the parsed response, with no live account.
- **FR-005**: Each provider MUST be swappable into the execution loop (feature 006) and able to drive a scripted goal to `completed` using that provider.
- **FR-006**: Each provider MUST return structured errors (missing config, network failure, non-200, malformed response, unknown tool) consistently with feature 004, never crashing.
- **FR-007**: The active provider MUST be selectable by configuration (global or per session) without any change to agent or loop code.
- **FR-008**: All five providers (the four here plus the reference from 004) MUST be interchangeable so the same goal completes identically regardless of which is selected.
- **FR-009**: Switching the active provider MUST NOT require modifying existing provider implementations (Open/Closed per the constitution).
- **FR-010**: System MUST report a clear error if a requested provider name is not among the implemented set.

### Key Entities *(include if feature involves data)*

- **Provider Implementation**: A concrete backend (opencode / kilo / z.ai / kimi) satisfying the Provider interface. Attributes: name, configuration schema, request builder, response parser.
- **Provider Configuration**: The per-provider settings (endpoint, credential, model) supplied from outside; schema differs per provider but is selected via the shared interface.
- **Provider Registry**: The component that maps a provider name to its implementation and supplies the selected one to the agent/loop at setup.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: All four providers (opencode, kilo, z.ai, kimi) each send a correctly shaped request and parse a mocked response with tool calls against a mock endpoint — verified by automated tests (100% of the four).
- **SC-002**: Each of the four providers drives a scripted goal to `completed` through the execution loop (feature 006) using fakes for tools — verified by automated tests (100% of the four).
- **SC-003**: All five providers (four here + reference) are interchangeable: the same scripted goal completes identically regardless of which is selected — verified by automated tests.
- **SC-004**: Each provider's error cases (missing config, network failure, non-200, malformed response, unknown tool) return structured errors in 100% of test cases with no process crash.
- **SC-005**: The master spec provider requirement is fully closed: five backends, each independently configurable and testable, satisfying FR-004 and SC-003 of the master spec.

## Assumptions

- **Built on feature 004**: The Provider interface, completion shape (text/tool-calls/finished), configuration-error behavior, and error contract are defined in feature 004; this feature only adds four implementations against that contract.
- **Interface-first (constitution)**: Per the project constitution (Dependency Inversion, SOLID, Open/Closed), the four providers implement the existing interface and are registered; existing code is not modified to add them.
- **Response-shape variance**: The four providers may differ in exact request/response formatting; each owns its own builder/parser. The testable contract is: send correct request for that provider, parse its tool-call responses.
- **Configuration varies per provider**: Some backends need an API key, some a token, some neither; the configuration layer must support each without coupling. Exact field sets are an implementation detail.
- **Mock, not live**: Tests use mock/recorded endpoints (or fakes); no live accounts or credentials are required to validate behavior.
- **No new agent behavior**: This feature adds backends only; the agent loop, tools, and goal model are unchanged and supplied by earlier features.
- **Language**: Implementation is in Zig per the overarching project constraint; this spec describes behavior, not code.

## Note on Scope (relationship to master spec 001)

The master feature requires exactly five providers (FR-004) and that each be usable to complete a goal (SC-003). Feature 004 delivered the interface + the OpenAI-compatible reference. This feature delivers the remaining four (opencode, kilo, z.ai, kimi) behind that same interface, closing the requirement across all five backends.
