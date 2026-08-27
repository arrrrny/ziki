# Research: Proxy Config (Phase 0)

Consolidated findings for spec `009-proxy-config`.

## Decision 1 — How to set a proxy on `std.http.Client`

**Decision**: Build a `std.http.Client.Proxy` struct and assign it to
`client.http_proxy` (and `client.https_proxy`) inside `HttpTransport.request`,
right after constructing the per-request client.

**Rationale**:
- `std.http.Client.Proxy` is a public struct:
  `{ protocol: Protocol, host: []const u8, authorization: ?[]const u8, port: u16, supports_connect: bool }`.
- `client.fetch` already respects `client.http_proxy` (for plain/http targets) and
  `client.https_proxy` (for tls/https targets): it connects to the proxy and, for
  https targets, opens a `CONNECT` tunnel when `supports_connect == true`.
- A fresh client is already created per request in `HttpTransport.request`, so setting
  the proxy there is the natural seam and keeps connection reuse out of the picture.

**Alternatives considered**:
- Patching `OpenAIProvider` to know about proxies — rejected: violates SRP/DIP; the
  provider must stay transport-agnostic.
- A global/default proxy on a shared client — rejected: the current design intentionally
  creates a client per request to avoid proxy keep-alive stalls; a shared client would
  reintroduce that risk.

## Decision 2 — Disable system-wide proxy auto-detection (FR-005)

**Decision**: ziki MUST NOT call `std.http.Client.initDefaultProxies`, and MUST set
`http_proxy`/`https_proxy` explicitly only when the user configured one. When no proxy is
configured, leave both fields `null`.

**Rationale**:
- `initDefaultProxies(client, arena)` is a separate opt-in function; `fetch` does NOT
  call it. Therefore simply never calling it means the standard `http_proxy` /
  `https_proxy` / `all_proxy` environment variables are ignored.
- Because `initDefaultProxies` only populates a field when it is `null`, explicitly
  assigning our configured proxy (or leaving `null` when unset) guarantees our value — or
  none — is what the client uses. There is no silent fallback to the OS proxy.

**Alternatives considered**:
- Clearing proxy env vars at startup — rejected: fragile, affects child processes spawned
  by tools, and is a global side effect. The opt-out via "never call initDefaultProxies"
  is sufficient and local.

## Decision 3 — Proxy URL parsing

**Decision**: Parse the configured proxy string with `std.Uri` to derive `protocol`
(`.plain` for `http`, `.tls` for `https`), `host`, and `port` (explicit port, else 80 for
plain / 443 for tls). `authorization` is `null` (no authenticated proxy needed). Set
`supports_connect = true` so https targets can tunnel.

**Rationale**: The user's proxy is `http://localhost:8890` (plain, port 8890) — the
common case parses trivially. Using `std.Uri` reuses the same parser `std.http` uses, so
behavior matches the library.

**Alternatives considered**:
- Hand-rolled split on `://` — rejected: `std.Uri` already handles edge cases and host
  extraction; reinventing it duplicates logic (DRY).

## Decision 4 — Error reporting (FR-007)

**Decision**: Parse/validate the proxy at `HttpTransport.init` (startup, before any goal
turn). A malformed proxy URL (bad scheme, missing host, unparseable port) returns an error
that `main.zig` surfaces as `error: <message>` and aborts before the goal loop starts.

**Rationale**: Satisfies "report a configuration error at startup, not mid-goal" and
"MUST NOT hang" — an unreachable proxy fails fast at the first `fetch` with a clear
connection error rather than stalling the loop.

## Open items

None. All NEEDS CLARIFICATION resolved via documented spec assumptions:
- Single `proxy` field (not per-provider) applied to the active provider.
- Field name `proxy` in JSON and `ZIKI_PROXY` for env override (consistent with existing
  `ZIKI_PROVIDER`/`ZIKI_ENDPOINT`/`ZIKI_MODEL`/`ZIKI_API_KEY` precedence).
