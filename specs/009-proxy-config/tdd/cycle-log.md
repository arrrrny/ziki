# Cycle Log: Proxy Config

Append only. Newest last. Every entry's `red` block is the evidence that the test
existed and failed before the implementation.

## Baseline

- suite: `zig build test` -> 40 passed, 0 failed (green)
- commit: `9376b03`
- recorded: cycle 0, before any change
- note: brownfield — feature already implemented and mostly tested. The list
  (`tdd/test-list.md`) records covered behaviors as DONE and the coverage gaps
  (U4, U7, U11, U12, U13; outer A1–A4 are live-only) as PENDING. The loop closes
  gaps with characterization/integration tests, not new implementation.

## Live acceptance validation (2026-08-26, commit 9376b03)

Outer-loop acceptance behaviors A1-A4 validated live against the running proxy
at `http://localhost:8890` using the `kilo` provider with active key `key1`
(`ahmet@iloveyumio.com`). Each scenario ran a trivial file-safe goal (`echo …`)
and observed `status: completed` (or the expected startup error).

- **A2 (direct, no proxy)** — Scenario B: `env -u ZIKI_PROXY ziki /goal …`
  completed; confirms key1 + direct connection works (no regression).
- **A1 (proxy routing)** — Scenario C: `ZIKI_PROXY=http://localhost:8890 ziki /goal …`
  completed through the proxy. (SC-003 proxy-traversal rate not measured
  proxy-side; covered by unit U9-U12.)
- **A4 (malformed proxy fast-fail)** — Scenario D: `ZIKI_PROXY=not-a-url ziki /goal …`
  → `error: invalid proxy URL in configuration`, goal never started (U13).
- **A3 (system proxy ignored)** — Scenario E:
  `http_proxy=http://127.0.0.1:9 ZIKI_PROXY= ziki /goal …` completed despite a
  dead system proxy, proving ziki never consults `http_proxy` (FR-005 / U9,U11).

Unit suite at validation: `zig build test` → 41/41 passed (green), after adding
the U7 test (`makeProxy parses https with explicit port`).

## Gap closure: U4, U11, U12 (2026-08-26, working tree on 9376b03)

Closed three remaining inner PENDING behaviors with in-process tests. The feature
is already implemented, so these are characterization / integration tests that add
no behavior. Suite after: `zig build test --summary all` → 44/44 passed, 0 leaked
(green).

- **U4** (T020): `src/config/config.zig::config proxy is empty (direct connection)
  when env and file leave it unset` — `Config.proxy == ""` when neither
  `ZIKI_PROXY` nor a file `proxy` key is set.
- **U11** (T017): `src/provider/transport.zig::HttpTransport routes HTTP requests
  through the configured proxy` — in-process HTTP proxy fixture asserts the
  request is routed through the proxy (`client.http_proxy`/`https_proxy` assigned,
  never `initDefaultProxies`). A stray `resp.body` leak was fixed with
  `defer alloc.free(resp.body)`.
- **U12** (T018): `src/provider/transport.zig::HttpTransport HTTPS-through-proxy
  fails on non-200 CONNECT` — the fixture answers CONNECT with 503; the manual
  CONNECT+TLS path (`requestViaConnectTls`) surfaces `error.ProxyConnectFailed`.

Remaining PENDING inner behavior: **U13** (T019, `main.runGoal` proxy wiring +
malformed fast-fail) — covered live by quickstart Scenario D only.

## Test grouping: non-TLS active vs TLS deferred (2026-08-26)

Audited all proxy tests for TLS requirement. None fail in a non-TLS environment
(U12 passes too — it fails fast at the CONNECT 503 before any handshake). To
scope the suite to the HTTP-proxy (non-TLS) scenario, the one test whose SUBJECT
is HTTPS/TLS was deferred — not because it fails, but because it exercises
`requestViaConnectTls` (the TLS path).

- **Active non-TLS group** (HTTP-only, no TLS execution) — `zig build test` →
  **43/43 passed, 0 leaked, ~10s**: U4 (config), FakeTransport contract,
  U5/U6/U7/U8 (makeProxy URL parsing), U9/U10 (init + system-proxy opt-out),
  U11 (HTTP target routed through in-process HTTP proxy — this scenario).
  Note: U6/U7 parse `https://` proxy URLs but perform NO socket/TLS; kept
  because they are genuinely non-TLS.
- **Deferred TLS group** — U12 moved to `src/provider/transport_tls.zig`, NOT
  imported by `tests.zig`. Runs standalone: `zig test
  src/provider/transport_tls.zig` → 9/9 (incl. U12). Deferred on subject
  (HTTPS/TLS), not on failure.

T018 (U12) marked DEFERRED in tasks.md; remaining PENDING: U13 (T019, live-only).
