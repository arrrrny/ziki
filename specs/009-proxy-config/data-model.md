# Data Model: Proxy Config (Phase 1)

## Entities

### Config (extended)

The resolved configuration loaded at startup. Gains one optional field.

| Field | Type | Required | Notes |
|-------|------|----------|-------|
| `active_provider` | `[]const u8` | yes* | unchanged from prior specs |
| `endpoint` | `[]const u8` | no | unchanged |
| `model` | `[]const u8` | no | unchanged |
| `api_key` | `[]const u8` | no | unchanged |
| `proxy` | `[]const u8` | **no (NEW)** | proxy URL; empty string means "no proxy / direct connection" |

\* A valid provider must be set or load fails (existing behavior).

**Validation rules (from FR-001..FR-007)**:
- `proxy` is optional. Empty/`""` ⇒ direct connection (FR-003, FR-005).
- `proxy` is overridable by the `ZIKI_PROXY` environment variable, which wins over the
  file value (matches the existing env-over-file precedence for provider settings).
- A non-empty `proxy` MUST be a parseable URL with a scheme (`http`/`https`), a host, and
  an optional port. If it cannot be parsed, configuration fails at startup with a clear
  error (FR-007) — no goal turn begins.
- A valid `proxy` is applied to the active provider's transport only; other providers are
  irrelevant (ziki uses one provider per run).

### Proxy Setting (transport-time)

Built from `Config.proxy` inside the transport. Not persisted; lives for the run.

| Attribute | Source | Notes |
|-----------|--------|-------|
| `protocol` | scheme of proxy URL | `.plain` (http) or `.tls` (https) |
| `host` | host of proxy URL | e.g. `localhost` |
| `port` | port of proxy URL or default (80/443) | e.g. `8890` |
| `authorization` | — | `null` (no auth proxy) |
| `supports_connect` | — | `true` (allows https tunneling) |

**Relationships**:
- `Config.proxy` (string) → parsed once → `std.http.Client.Proxy` assigned to
  `client.http_proxy` and `client.https_proxy` for every request of the active transport.

## State transitions

None beyond the existing load lifecycle. The proxy is either:
- **unset** → `client.http_proxy = null` → direct connection; OR
- **set + valid** → proxy applied → routed connection; OR
- **set + invalid** → startup error → process aborts before goal loop.

## Key entities referenced from spec

- **Proxy Setting** (spec Key Entities) ⇨ the parsed `std.http.Client.Proxy` above.
- **Provider Transport** (spec Key Entities) ⇨ `HttpTransport`, which honors the proxy.
