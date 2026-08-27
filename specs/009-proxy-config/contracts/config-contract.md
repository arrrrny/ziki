# Contract: Configuration Surface (Phase 1)

The public, user-facing configuration surface for the proxy feature. This is the contract
a user edits; implementation details belong in `tasks.md`.

## File: `~/.config/ziki/config.json`

Add one optional key to the existing object:

```json
{
  "active_provider": "cliproxy",
  "endpoint": "http://localhost:8317/v1",
  "model": "mimo-v2.5",
  "api_key": "quotio-local-366DEB2B-DB3F-4839-AD5E-B1D399D6E3ED",
  "proxy": "http://localhost:8890"
}
```

| Key | Required | Format | Meaning when absent |
|-----|----------|--------|---------------------|
| `proxy` | no | URL string `http[s]://host[:port]` | direct connection (no proxy) |

- Empty string `""` is treated identically to absent (direct connection).
- A malformed value (no scheme / no host / bad port) is a **startup error**, not a
  mid-goal error.

## Environment variable: `ZIKI_PROXY`

- Overrides the file `proxy` value when set (same precedence as `ZIKI_PROVIDER`,
  `ZIKI_ENDPOINT`, `ZIKI_MODEL`, `ZIKI_API_KEY`).
- Format identical to the file value.

## Behavior contract

| `proxy` value | Requests to provider |
|---------------|----------------------|
| absent / `""` | direct (system proxy env vars are ignored — FR-005) |
| valid URL | routed through that proxy |
| invalid URL | process aborts at startup with `error: <reason>` |

## Proxy URL grammar (accepted)

```text
proxy_url ::= scheme "://" host [ ":" port ]
scheme    ::= "http" | "https"
host      ::= <hostname or IP, e.g. "localhost">
port      ::= <1-65535>; default 80 for http, 443 for https
```

Only localhost proxies are required/supported by the user; non-localhost is not rejected
but is untested.
