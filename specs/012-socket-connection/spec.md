# Feature Specification: Local-Socket Agent-State Transport

**Feature Branch**: `012-socket-connection`

**Created**: 2026-08-27

**Status**: Draft

**Input**: User description: "socket connection"

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Report agent state over a local socket (Priority: P1)

Herdr runs the agent-state listener on a local Unix domain socket instead of (or
in addition to) a TCP port. Ziki must be able to deliver its existing
agent-state report to that socket using the same report payload and request
shape it already sends over HTTP, so the listener requires no contract change.

**Why this priority**: This is the core of the feature — it is what lets Ziki
talk to a socket-based Herdr listener without rewiring the integration contract
established in `specs/011-herdr-ziki-state-sync`. Delivering it alone is a
complete, valuable slice.

**Independent Test**: Can be fully tested by configuring Ziki with a socket URL,
starting a local socket listener that echoes/accepts the report, and asserting
the report is received with the same fields and request form as the HTTP path.

**Acceptance Scenarios**:

1. **Given** `HERDR_API_URL` is set to a local-socket address, **When** Ziki publishes an agent-state change, **Then** the report is delivered to the socket listener with the identical payload and request shape used by the HTTP transport.
2. **Given** `HERDR_API_URL` is a normal HTTP URL, **When** Ziki publishes, **Then** behavior is unchanged from today (HTTP transport still used).
3. **Given** the socket listener is running, **When** Ziki connects and sends the report, **Then** the listener's HTTP-shaped response is parsed and the delivery is recorded as successful.

---

### User Story 2 - Select the transport from configuration (Priority: P2)

The transport is chosen by the existing Herdr API URL configuration. A
socket-style address selects the socket transport; any other address keeps the
HTTP transport. This keeps a single configuration knob and stays backward
compatible with every existing deployment.

**Why this priority**: Backward compatibility matters — existing Herdr
deployments use an HTTP URL and must not change behavior. The selection rule is
small but must be explicit and tested.

**Independent Test**: Can be fully tested by feeding the configuration parser a
socket address and an HTTP address and asserting the correct transport is
selected in each case, with no effect on the other.

**Acceptance Scenarios**:

1. **Given** the API URL uses a socket scheme, **When** the transport is resolved, **Then** the socket transport is selected.
2. **Given** the API URL is an `http://` or `https://` address, **When** the transport is resolved, **Then** the HTTP transport is selected (unchanged).
3. **Given** the API URL uses an unrecognized scheme, **When** startup resolves the transport, **Then** startup fails fast with a clear, actionable message.

---

### User Story 3 - Degrade gracefully when the socket is unavailable (Priority: P3)

If the configured socket path does not exist, is not connectable, or rejects the
connection, Ziki must report a clear error and continue the goal loop. The
agent's task execution must not be blocked by a reporting failure — matching the
current HTTP failure handling.

**Why this priority**: Robustness for the common operational case (Herdr not yet
listening, wrong path). Important for production use but secondary to
establishing the delivery path itself.

**Independent Test**: Can be fully tested by configuring a socket address whose
path does not exist, running a publish, and asserting a clear error is produced
and the goal loop continues without crashing.

**Acceptance Scenarios**:

1. **Given** the configured socket path does not exist, **When** Ziki attempts to publish, **Then** a clear error is surfaced and the goal loop continues.
2. **Given** the socket path exists but no listener accepts, **When** Ziki attempts to publish, **Then** a clear connection error is surfaced and the goal loop continues.
3. **Given** the socket transport fails, **When** the goal finishes, **Then** the goal's result is unaffected by the reporting failure.

---

### Edge Cases

- Socket path is missing, a directory, or permission-denied.
- Socket scheme supplied but no listener is bound to the path.
- HTTP URL still configured (must remain the default, unchanged behavior).
- Unsupported/garbage URL scheme at startup → fail fast, not at publish time.
- Listener returns a non-2xx response over the socket → treated like an HTTP
  failure (report error, do not crash).

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Ziki MUST be able to deliver the agent-state report (per the `011` contract §2) over a local Unix domain socket in addition to the existing HTTP transport.
- **FR-002**: When the Herdr API URL is configured with a local-socket scheme, Ziki MUST select the socket transport; otherwise it MUST select the existing HTTP transport (backward compatible).
- **FR-003**: The socket transport MUST send the identical report payload and HTTP-shaped request as the HTTP transport, so the receiving listener requires no contract change.
- **FR-004**: The socket transport MUST be delivered as a new implementation behind the existing transport abstraction; the existing HTTP transport code MUST NOT be modified to add this behavior (constitution Principle III — extension via new code).
- **FR-005**: The socket transport MUST NOT introduce any third-party dependency (consistent with the project's zero-dependency policy).
- **FR-006**: If the configured socket path is missing or the connection is refused, Ziki MUST surface a clear, actionable error and MUST NOT block or crash the goal loop.
- **FR-007**: Ziki MUST validate the transport selection at startup and fail fast with a clear message if the URL scheme is unsupported.

### Key Entities

- **Transport abstraction**: the dependency-injected boundary the provider uses to send requests; new transports plug in without changing consumers.
- **Socket transport**: the new implementation that delivers the report over a local Unix domain socket using the same HTTP-shaped request.
- **Herdr agent-state listener**: the external consumer of the report; it MAY bind to a socket instead of a TCP port, but its accepted request/response contract is unchanged by this feature.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Agent-state reports reach a socket-based listener with delivery behavior equivalent to the HTTP path (same payload, same success/failure outcomes).
- **SC-002**: 100% of existing report-push behavior is preserved when routed through the socket transport — no change to the Herdr-side contract.
- **SC-003**: A missing or unreachable socket path yields a clear error and leaves goal execution fully functional (the agent still completes its task).
- **SC-004**: The feature adds zero new third-party dependencies to the build.
- **SC-005**: All transport-selection cases (socket, HTTP, unsupported scheme) are covered by tests and behave as specified.

## Assumptions

- Herdr's listener can be bound to a Unix domain socket and will accept the same HTTP-shaped request it accepts over TCP (the `011` contract §2 request form is transport-agnostic).
- Ziki remains a client that pushes state; this feature does NOT add a listener/server inside Ziki (that remains explicitly out of scope, consistent with `011` contract §6).
- The existing single configuration knob (`HERDR_API_URL`) is sufficient to select the transport; no new required setting is introduced.
- "Local socket" means a Unix domain socket on the same host; cross-host transport is out of scope.
