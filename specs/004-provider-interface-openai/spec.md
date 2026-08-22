# Feature Specification: Provider Interface & OpenAI-Compatible Reference

**Feature Branch**: `[004-provider-interface-openai]`

**Created**: 2026-08-22

**Status**: Draft

**Input**: User description: "Provider abstraction and OpenAI-compatible reference provider for the Zig Goal CLI. The agent must talk to a model backend to pursue goals. All model backends MUST be accessed through a single injectable Provider interface (Dependency Inversion per the constitution) so the agent loop and tests never depend on a concrete network client. This feature delivers that interface plus ONE working implementation: an OpenAI-compatible provider that sends a conversation (system prompt + message history + tool descriptions) and receives a completion that may include tool calls, using standard request/response shapes. The provider MUST be independently testable: in tests it is exercised against a mock/recorded HTTP endpoint (or a fake provider) so the exact request sent and the parsing of the response are asserted without a live account. Definition of done: the Provider interface exists, the OpenAI-compatible implementation correctly sends a request and parses a response (including tool-call results) against a mock endpoint, and a fake provider can drive the agent loop in tests. This is the backend the autonomous goal execution feature will depend on; the other four named providers (opencode, kilo, z.ai, kimi) are separate later features that implement the same interface."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Send a conversation and get a completion (Priority: P1)

The agent hands the provider a system prompt, the message history, and the available tool descriptions, and receives back a completion. The completion is either free text, one or more tool calls, or a finish signal. This works through the interface so the agent never knows which backend answered.

**Why this priority**: This is the single capability the whole goal loop depends on; without it no goal can be pursued.

**Independent Test**: Drive the OpenAI-compatible provider against a mock endpoint that returns a canned completion; assert the request body contains the system prompt, history, and tool descriptions, and that the parsed completion matches the canned response.

**Acceptance Scenarios**:

1. **Given** a system prompt, two prior messages, and one tool description, **When** a completion is requested, **Then** the sent request carries exactly those inputs and the returned completion is the mocked text.
2. **Given** a mocked response containing a tool call, **When** parsed, **Then** the completion exposes the tool name and arguments so the agent can execute the tool.
3. **Given** a mocked "finished" response, **When** parsed, **Then** the completion signals the agent to stop rather than loop.

---

### User Story 2 - Swap the backend without touching the agent (Priority: P1)

Because the agent depends only on the Provider interface, the concrete OpenAI-compatible client can be replaced by a fake in tests, and later by the other real providers, with no change to agent code.

**Why this priority**: This is the constitution's Dependency Inversion mandate and what makes the system testable and extensible; it is a shippable property on its own.

**Independent Test**: Register a fake provider that records the conversation it received and returns a scripted completion; run the agent loop against it and assert the exact inputs the agent sent and the scripted outputs it acted on, with no network call.

**Acceptance Scenarios**:

1. **Given** a fake provider registered in place of the real one, **When** the agent requests a completion, **Then** the fake records the full conversation and the agent proceeds on the scripted reply, proving no concrete client is referenced above the interface.
2. **Given** a different provider implementation supplying the same interface, **When** swapped at setup, **Then** the agent loop behaves identically.

---

### User Story 3 - Configure the reference provider (Priority: P2)

The OpenAI-compatible provider is configured with an endpoint URL, a credential, and a model name, supplied from outside (global or per session). Invalid or missing configuration is reported clearly before any request is attempted.

**Why this priority**: Without configuration the provider cannot be used; clear errors here prevent obscure failures during goal runs.

**Independent Test**: Construct the provider with a valid config and assert a request is attempted; construct with missing credential and assert a clear configuration error is returned before any network use.

**Acceptance Scenarios**:

1. **Given** a valid endpoint, credential, and model, **When** the provider is built, **Then** it is ready to send requests.
2. **Given** a missing credential, **When** the provider is built or used, **Then** a clear "provider not configured" error is produced and no request is sent.

---

### Edge Cases

- Network failure or timeout: the provider returns a structured error (not a crash) and the agent can retry or report.
- Non-200 HTTP status from the endpoint: surfaced as a clear error carrying the status, not silently swallowed.
- Malformed/truncated response body: parsed safely into an error rather than causing undefined behavior.
- Response contains neither text nor a valid tool call: treated as an error or no-op per a defined rule.
- Token/context limit exceeded: the provider reports the limit error so the agent can compact context and retry.
- Tool description or message too large for the backend: the provider reports the rejection clearly.
- Unexpected tool name in a response (not among provided tools): the agent is told the tool is unknown rather than attempting to call it.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST expose all model backends through a single injectable Provider interface so the agent depends on the interface, not on a concrete client (Dependency Inversion).
- **FR-002**: The Provider interface MUST accept a system prompt, message history, and tool descriptions, and MUST return a structured completion.
- **FR-003**: The completion result MUST represent one of: free-text reply, one or more tool calls (name + arguments), or a finish signal, in a form the agent can act on.
- **FR-004**: System MUST deliver an OpenAI-compatible provider implementation that sends the conversation and tool descriptions and parses the standard response shape, including tool calls.
- **FR-005**: The OpenAI-compatible provider MUST be testable against a mock/recorded endpoint so the exact request and the parsed response are asserted without a live account.
- **FR-006**: System MUST allow a fake provider (same interface) to drive the agent loop in tests, recording inputs and returning scripted completions, with no network use.
- **FR-007**: The provider MUST be configurable with endpoint, credential, and model from outside (global or per session).
- **FR-008**: The provider MUST report a clear configuration error (no request sent) when required configuration is missing or invalid.
- **FR-009**: The provider MUST return structured errors (network failure, non-200 status, malformed response, limit exceeded) rather than crashing the process.
- **FR-010**: The provider MUST surface an unknown tool name in a response as a clear error so the agent does not attempt to call an unprovided tool.

### Key Entities *(include if feature involves data)*

- **Provider**: The model-backend abstraction behind the injectable interface. Attributes: configuration (endpoint, credential, model), request method, result.
- **Completion**: The structured outcome of a model request. Attributes: kind (text / tool-calls / finished), text payload, tool-call list (name + arguments), error detail.
- **Conversation**: The inputs sent to a provider. Attributes: system prompt, message history, tool descriptions.
- **Provider Registry / Injector**: The component that supplies the active provider implementation (real or fake) to the agent at setup.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: The Provider interface exists and the agent depends solely on it; 100% of agent provider usage is exercisable via a fake with zero network access (asserted by test).
- **SC-002**: The OpenAI-compatible implementation sends a request carrying the system prompt, full history, and tool descriptions, and correctly parses a mocked completion including tool calls — verified by automated tests against a mock endpoint (100% of these cases).
- **SC-003**: All error cases (missing config, network failure, non-200, malformed response, limit exceeded, unknown tool) return structured errors in 100% of test cases with no process crash.
- **SC-004**: A fake provider can drive the agent loop end-to-end in tests, recording exact inputs and returning scripted outputs, proving backend swap-ability.
- **SC-005**: The reference provider is usable to complete at least one scripted agent turn that produces and consumes a tool call, demonstrating the full request/response contract.

## Assumptions

- **Interface-first (constitution)**: Per the project constitution (Dependency Inversion, SOLID), the agent MUST depend only on the Provider interface; concrete clients are injected. Non-negotiable.
- **One implementation now, four later**: This feature ships the interface + the OpenAI-compatible reference. The other four named providers (opencode, kilo, z.ai, kimi) are separate later features that implement the same interface; this spec does not build them.
- **Standard shapes**: "OpenAI-compatible" means the common request/response contract (messages + tools in, choices/tool_calls out). Exact field names are an implementation detail; the testable contract is the conversation-in / completion-out behavior including tool calls.
- **Tool calls in completion**: The provider must be able to return tool invocations the agent then executes via the Tool layer (feature 003); the two features meet at the agent loop (a later feature).
- **Configuration source**: Endpoint/credential/model come from outside the provider (global config or per-session), not hard-coded.
- **Language**: Implementation is in Zig per the overarching project constraint; this spec describes behavior, not code.

## Note on Scope (relationship to master spec 001)

The master feature (001-zig-goal-cli) requires five providers total. This spec delivers the abstraction plus one (OpenAI-compatible custom). The remaining four (opencode, kilo, z.ai, kimi) are intentionally deferred to their own later specs so each remains a small, independently shippable and testable feature.
