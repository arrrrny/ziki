# Feature Specification: Lane E — Herdr/skills e2e + spec 012 + two confirmed bugs

**Feature Branch**: `fix/lane-e-herdr-skills-e2e`

**Created**: 2026-09-15

**Status**: Draft (synthesized by bug.fix from [assessment.md](../assessment.md) — issue arrrrny/ziki#20)

**Input**: GitHub issue #20 — "[Lane E] Herdr/skills e2e + spec 012 + two confirmed bugs (use-after-free, SESSION_ID)"

## User Scenarios & Testing *(mandatory)*

### Bug 1 — Herdr use-after-free (P1)

`buildStatePublisher` (`src/main.zig:113-115`) frees `api_url` right after
`HerdrHttpClient.init` stored it **by reference** (`src/agent/herdr.zig:16` does no
dupe). Any real reporter use reads freed memory.

**Acceptance Scenarios**:

1. **Given** a `HerdrHttpClient` constructed with a caller-owned URL, **When** the caller frees its copy and the client reports, **Then** the request uses the original URL and the run survives `std.testing.allocator` (no use-after-free, no leak).
2. **Given** the client is dropped, **When** it is deinitialized, **Then** the owned URL copy is freed.

### Bug 2 — SESSION_ID hard-coded to "default" (P1)

`src/main.zig:35` pins the session id to `"default"` (used at `:241`, `:251` and by
`/stop`, `/status`, `/goals`), breaking per-window goal isolation when multiple Ziki
instances run side by side.

**Acceptance Scenarios**:

1. **Given** `ZIKI_SESSION_ID` is set, **When** a session id is resolved, **Then** it is used verbatim.
2. **Given** only `HERDR_PANE_ID` is set, **When** a session id is resolved, **Then** the pane id is used (a herdr pane is exactly the per-window identity of the swarm).
3. **Given** neither is set, **When** a session id is resolved, **Then** the historical `"default"` is used (backward compatible).
4. **Given** two resolved session ids, **When** two repositories share one state dir, **Then** each persists and loads only its own goal (repository isolation).

### Feature 1 — Skill-driven end-to-end goal test (P2, spec 009-skill-system)

A full loop: load a skill from disk → verify it appears in the system prompt listing →
executor fetches it via the `skill` tool → artifact written. Uses `FakeProvider` +
`FakeFs` + `tmpDir` (a real on-disk skill root via `RealFs`).

**Acceptance Scenarios**:

1. **Given** a skill directory on disk in a tmpDir, **When** the registry loads from it, **Then** the skill appears in the listing text placed in the system prompt.
2. **Given** a scripted provider that fetches the skill by name, **When** the goal loop runs, **Then** the skill tool returns the skill body and the loop writes the artifact file.
3. **Given** the run finishes, **Then** the goal is completed and the artifact content matches the skill's instruction.

### Feature 2 — Spec 012 local-socket transport (P2)

Port the spec draft from `origin/012-socket-connection` onto master and add a socket
transport behind the existing `Transport` interface.

**Acceptance Scenarios**:

1. **Given** a `unix://` URL, **When** the transport is selected, **Then** the socket transport is chosen; `http://`/`https://` keep HTTP; any other scheme is unsupported (fail fast at selection).
2. **Given** a listener on a Unix domain socket, **When** the transport POSTs, **Then** the request is HTTP-shaped (request line, Host, Content-Type, Content-Length, body) — identical to the HTTP path (FR-003) — and the listener's HTTP-shaped response is parsed (status + body).
3. **Given** a socket path that does not exist, **When** the transport requests, **Then** a clear error propagates and the reporter swallows it (goal loop unaffected, FR-006).

## Requirements

- **FR-A (bug 1)**: `HerdrHttpClient` owns its `base_url` (dupe in `init`, free in `deinit`); callers keep their own lifetime.
- **FR-B (bug 2)**: session id resolved at startup from `ZIKI_SESSION_ID`, else `HERDR_PANE_ID`, else `"default"`; threaded through goal/stop/status/goals paths; stop-file path built at runtime.
- **FR-C (feature 1)**: test-only — no production change; the e2e test lives in the suite via the `tests.zig` aggregator.
- **FR-D (feature 2)**: new `SocketTransport` behind the existing `Transport` vtable; no modification of the HTTP transport (constitution Principle III); zero new dependencies; selection by URL scheme with fail-fast on unsupported schemes.

## Success Criteria

- `zig build test` green; bug fixes each carry a regression test.
- Socket transport tests cover selection, wire shape, response parse, and failure degradation.
- No leaks under `std.testing.allocator` in touched code paths.
