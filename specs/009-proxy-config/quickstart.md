# Quickstart & Validation: Proxy Config (Phase 1)

Runnable scenarios that prove spec `009-proxy-config` works end-to-end. Implementation
details live in `tasks.md`; this is the validation guide.

## Prerequisites

- Zig 0.15.2 toolchain.
- A reachable local proxy at `http://localhost:8890` (the user's existing Quotio proxy).
- A reachable provider behind it (cliproxy at `http://localhost:8317/v1`, model `mimo-v2.5`).

## Scenario A — Unit tests (no network)

```bash
zig build test --summary all
```

**Expected**: all tests green (prior 26 + new proxy tests). New tests cover:
- config loads `proxy` from JSON and honors `ZIKI_PROXY` precedence; empty ⇒ no proxy;
- malformed proxy URL is rejected by the parser;
- a parsed proxy yields correct `protocol`/`host`/`port` (e.g. `http://localhost:8890`
  ⇒ plain / localhost / 8890).

## Scenario B — Direct connection unchanged (regression guard)

Config with **no** `proxy` key (the user's current working config). Run:

```bash
ziki /goal "Use run_command to print the word ZIKI_DIRECT_OK" --criterion "output contains ZIKI_DIRECT_OK"
```

**Expected**: `status: completed`, criterion satisfied. Identical to pre-proxy behavior.

## Scenario C — Proxied connection (acceptance, SC-001)

Set the proxy and run the same goal:

```bash
ZIKI_PROXY="http://localhost:8890" \
  ziki /goal "Use run_command to print the word ZIKI_PROXY_OK" --criterion "output contains ZIKI_PROXY_OK"
```

**Expected**:
- `status: completed`, criterion satisfied.
- The request traversed `http://localhost:8890` (the live proxy forwards to the provider).
- Outcome identical to Scenario B.

## Scenario D — Invalid proxy fails fast (FR-007)

```bash
ZIKI_PROXY="not-a-url" ziki /goal "do nothing" --criterion "x"
```

**Expected**: process prints `error: <reason>` and exits before the goal loop starts
(no hang, no partial run).

## Scenario E — System proxy ignored (FR-005)

With an `http_proxy` env var set but **no** ziki `proxy` configured:

```bash
http_proxy="http://127.0.0.1:9" ziki /goal "print ZIKI_NO_SYS_PROXY" --criterion "output contains ZIKI_NO_SYS_PROXY"
```

**Expected**: goal completes directly (the bogus system proxy at port 9 is NOT used).

## Definition of Done (per spec)

Scenarios A–E pass; Scenario C verifies the live localhost:8890 proxy end-to-end.
