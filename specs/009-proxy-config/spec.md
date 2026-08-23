# Feature Specification: Proxy Config

**Feature Branch**: `009-proxy-config`

**Created**: 2026-08-23

**Status**: Draft

**Input**: User description: "add a proxy config that if it is set the requests will go through the set proxy, I have the http://localhost:8890 on kimi I want the same, no need for a global support only localhost proxies are fine just make it as a config. luckily since I already have one http://localhost:8890 you can test it."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Route requests through a configured localhost proxy (Priority: P1)

As a ziki user who already runs a local proxy (for example the one I operate at
`http://localhost:8890`), I want to set a proxy URL in my configuration so that
every request ziki sends to the model provider is routed through that proxy —
exactly the way kimi does today. This lets me keep my existing local proxy
setup when driving ziki.

**Why this priority**: This is the whole feature. Without it, ziki cannot operate
in an environment where the provider is only reachable through the local proxy,
which blocks the user's workflow.

**Independent Test**: Set the proxy field in the configuration to a reachable
localhost proxy, run a goal, and confirm the goal completes with the same result
as a direct connection. The user can demonstrate this today against
`http://localhost:8890`.

**Acceptance Scenarios**:

1. **Given** a config with a valid proxy URL pointing at a reachable localhost proxy, **When** ziki runs a goal, **Then** all outbound requests to the provider are sent through that proxy and the goal completes successfully.
2. **Given** a config with no proxy field, **When** ziki runs a goal, **Then** requests go directly to the provider and behavior is unchanged from the current build.

---

### User Story 2 - Configure the proxy without global/system proxy support (Priority: P2)

As a user, I want the proxy to be a simple configuration value (right alongside
the provider and model), without ziki trying to auto-detect system-wide proxy
settings such as the `http_proxy` environment variable. I only need localhost
proxies.

**Why this priority**: Keeps the feature minimal and predictable. The user
explicitly does not want global proxy support, so avoiding it reduces surface
area and surprise.

**Independent Test**: With no system proxy variable set and no proxy in ziki's
config, a goal connects directly. With a proxy set in ziki's config, only that
proxy is used and system settings are never consulted.

**Acceptance Scenarios**:

1. **Given** no proxy configured in ziki and a system `http_proxy` variable present, **When** ziki runs, **Then** ziki ignores the system proxy and connects directly.
2. **Given** a proxy set in ziki's config, **When** ziki runs, **Then** only that configured proxy is used; system settings are not consulted.

---

### Edge Cases

- What happens when the configured proxy is unreachable (host down / port closed)? ziki MUST surface a clear connection error rather than hang silently.
- What happens when the proxy URL is malformed (missing scheme, bad port)? ziki MUST report a configuration error at startup, not mid-goal.
- What happens when the proxy field is present but empty? Treated as "no proxy" (direct connection).
- What happens when both an environment override and a config proxy are set? The environment value wins (matches the existing precedence used for provider settings).

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The configuration MUST allow the user to specify a proxy URL as a single setting.
- **FR-002**: When a proxy is configured, ziki MUST route every outbound request to the model provider through that proxy.
- **FR-003**: When no proxy is configured, ziki MUST connect directly to the provider (identical to current behavior).
- **FR-004**: The proxy setting MUST be read from the same configuration file that holds the provider settings, and MUST be overridable by an environment variable.
- **FR-005**: ziki MUST NOT auto-detect or use system-wide/global proxy settings; only the explicitly configured proxy is used.
- **FR-006**: A goal executed through a reachable configured proxy MUST complete with the same final outcome (objective met / criterion satisfied) as the equivalent direct connection.
- **FR-007**: If the configured proxy cannot be reached, ziki MUST report a clear, actionable error and MUST NOT hang.

### Key Entities *(include if feature involves data)*

- **Proxy Setting**: A URL (scheme + host + port) stored in configuration. Applied to the active provider's transport. Optional; empty means direct connection.
- **Provider Transport**: The mechanism that delivers requests to the model backend; it MUST honor the proxy setting when present.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: With the proxy set to the user's live localhost proxy (`http://localhost:8890`), a goal against the cliproxy provider completes with status "completed" and the completion criterion satisfied — verified live.
- **SC-002**: With the proxy unset, the full existing test suite remains green (no regression in direct-connection behavior).
- **SC-003**: 100% of outbound provider requests during a proxied run traverse the configured proxy (validated via the local proxy that forwards requests).
- **SC-004**: A malformed or unreachable proxy produces an immediate, human-readable error instead of a silent stall.

## Assumptions

- The configuration file is the same file currently used for provider settings (flat key/value store at `~/.config/ziki/config.json`); the proxy is added as one new field there. When the TOML config format is introduced later, the same field name applies.
- Only localhost proxies are required by the user; non-localhost proxies are not explicitly supported or tested, but the implementation does not need to reject them.
- The existing proxy at `http://localhost:8890` is reachable during testing and forwards to the configured provider endpoint.
- The proxy is applied to the single active provider (ziki uses one provider per run); per-provider proxy selection is out of scope.
- The environment variable override follows the prefix pattern already established for provider settings (e.g., `ZIKI_PROXY`).
