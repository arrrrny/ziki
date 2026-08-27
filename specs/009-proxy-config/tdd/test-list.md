---
feature: 009-proxy-config # spec-kit feature directory name
loop: outside-in # acceptance test written first; here it is a live CLI scenario
profile: .specify/memory/tdd-profile.md # stack profile the commands must read
spec_criteria: 4 # acceptance scenarios in spec.md (US1: 2, US2: 2)
planned_at: 9376b03 # short SHA the list was derived from
updated_at: 9376b03 # short SHA of the last change to this file
suite_baseline: green # green | red | unknown, at planning time
---

# Test List: Proxy Config

**Status**: Brownfield. The feature is already implemented in `config.zig`,
`transport.zig`, and `main.zig`, and most behaviors already have passing tests
(in the green 40-test suite). This list records what is covered (`DONE`) and the
remaining gaps (`PENDING`). The gaps are untested existing behavior, so the loop
closes them with characterization / integration tests rather than new
implementation.

**Outer loop note**: the four acceptance behaviors are live CLI scenarios that
require a running local proxy at `http://localhost:8890` plus a provider behind
it. The stack profile has **no acceptance/E2E runner** (see
`.specify/memory/tdd-profile.md`), so A1–A4 are validated manually via
`quickstart.md` scenarios B–E, not by `zig build test`.

## Outer loop: acceptance behaviors

One per acceptance scenario in `spec.md`. Each stays red until the feature works
end to end through its real entry point (the `ziki` CLI with a live proxy).

| id  | behavior                                                                                  | traces                  | kind    | state    | test                                  |
| --- | ----------------------------------------------------------------------------------------- | ----------------------- | ------- | -------- | ------------------------------------- |
| A1  | Given a valid localhost proxy in config/env, a goal completes through that proxy (same outcome as direct) | US1-AC1, FR-002, FR-006, SC-001 | example | DONE    | live: Scenario C (key1/kilo + ZIKI_PROXY=http://localhost:8890) — goal completed 2026-08-26      |
| A2  | Given no proxy, a goal connects directly with behavior unchanged from the current build    | US1-AC2, FR-003, SC-002  | example | DONE    | live: Scenario B (key1/kilo, no proxy) — goal completed; suite 41/41 green   |
| A3  | Given a system `http_proxy` and no ziki proxy, ziki ignores the system proxy and connects direct | US2-AC1, FR-005   | example | DONE    | live: Scenario E (dead http_proxy=127.0.0.1:9, no ziki proxy) — goal completed                       |
| A4  | Given a ziki proxy set, only that proxy is used; system settings are not consulted          | US2-AC2, FR-005          | example | DONE    | live: Scenario D (malformed proxy) — startup error "invalid proxy URL in configuration"; Scenario E confirms system ignored       |

## Inner loop: unit behaviors

Grouped by the component from `plan.md` that owns them. Each line names one
observable result.

### `src/config/config.zig`

| id  | behavior                                                                       | traces          | kind    | state   | test                                                                  |
| --- | ------------------------------------------------------------------------------ | --------------- | ------- | ------- | --------------------------------------------------------------------- |
| U1  | Config loads `proxy` from the JSON `proxy` key                                 | FR-001, FR-004  | example | DONE    | `src/config/config.zig::load exposes proxy from config/env without mutating env` |
| U2  | `ZIKI_PROXY` env overrides the file `proxy` value (env wins)                   | FR-004          | example | DONE    | `src/config/config.zig::proxy precedence: env overrides file; malformed carried verbatim` (+ U1 test env path) |
| U3  | A malformed proxy value is carried verbatim from config; the transport rejects it at startup | FR-004, FR-007 | example | DONE    | `src/config/config.zig::proxy precedence: env overrides file; malformed carried verbatim` |
| U4  | `Config.proxy == ""` when neither env nor file sets it (direct connection)      | FR-003          | example | DONE    | `src/config/config.zig::config proxy is empty (direct connection) when env and file leave it unset` |

### `src/provider/transport.zig`

| id  | behavior                                                                                        | traces          | kind    | state   | test                                                                  |
| --- | ----------------------------------------------------------------------------------------------- | --------------- | ------- | ------- | --------------------------------------------------------------------- |
| U5  | `makeProxy("http://localhost:8890")` → `.plain` / `"localhost"` / `8890` / `supports_connect`    | FR-002          | example | DONE    | `src/provider/transport.zig::makeProxy parses http://localhost:8890`  |
| U6  | `makeProxy("https://host")` → `.tls` / default port `443`                                        | FR-002          | example | DONE    | `src/provider/transport.zig::makeProxy parses https with default port` |
| U7  | `makeProxy("https://host:3128")` → `.tls` / explicit port `3128`                                 | FR-002          | example | DONE    | `src/provider/transport.zig::makeProxy parses https with explicit port`         |
| U8  | `makeProxy` rejects a malformed URL with `error.InvalidProxyUrl`                                 | FR-007          | example | DONE    | `src/provider/transport.zig::makeProxy rejects malformed url`         |
| U9  | `HttpTransport.init(null)` → `proxy == null` (system proxy ignored, direct)                      | FR-003, FR-005  | example | DONE    | `src/provider/transport.zig::HttpTransport with no proxy stores null (system proxy ignored)` |
| U10 | `HttpTransport.init(valid url)` → `proxy != null` with correct host/port                         | FR-002          | example | DONE    | `src/provider/transport.zig::HttpTransport with proxy stores parsed proxy` |
| U11 | `HttpTransport.request` (HTTP target) assigns `client.http_proxy`/`https_proxy` from the configured proxy and never calls `initDefaultProxies` | FR-002, FR-005 | example | DONE    | `src/provider/transport.zig::HttpTransport routes HTTP requests through the configured proxy` |
| U12 | HTTPS target through a proxy uses manual CONNECT+TLS (`requestViaConnectTls`)                    | FR-002          | example | DEFERRED | moved to `src/provider/transport_tls.zig` (NOT collected by `tests.zig`) — see "Deferred (TLS) group" below |

### `src/main.zig`

| id  | behavior                                                                                          | traces                    | kind    | state    | test                                            |
| --- | ------------------------------------------------------------------------------------------------- | ------------------------- | ------- | -------- | ----------------------------------------------- |
| U13 | `runGoal` passes `cfg.proxy` into `HttpTransport.init`; a malformed proxy fails fast at startup with `error: invalid proxy URL in configuration` | FR-002, FR-004, FR-007 | example | PENDING  | (no test; live `quickstart.md` Scenario D)      |

## Deferred (TLS) group

Out of scope for the non-TLS HTTP-proxy scenario. Excluded from the default
`zig build test` run by NOT importing the file in `tests.zig`, so the active
suite stays genuinely all-green with **no TLS execution**. The test still
compiles and passes when run on its own (`zig test src/provider/transport_tls.zig`
→ 9/9). Deferred on its SUBJECT (HTTPS/TLS), not because it fails.

| id  | behavior                                                                          | traces   | kind    | state     | test                                                                  |
| --- | --------------------------------------------------------------------------------- | -------- | ------- | --------- | --------------------------------------------------------------------- |
| U12 | HTTPS target through a proxy uses manual CONNECT+TLS (`requestViaConnectTls`)      | FR-002   | example | DEFERRED  | `src/provider/transport_tls.zig::HttpTransport HTTPS-through-proxy fails on non-200 CONNECT` |

## Invariants and edge cases still to place

Behaviors that belong to the feature but do not yet have a home component. Each
must become a numbered line above before the feature is done, or be dropped with
a reason.


- Unreachable proxy (host down / port closed) surfaces a clear connection error and
  does not hang (FR-007 edge case). Currently only `requestViaConnectTls` returns
  `error.ProxyConnectFailed`, untested — folds into U12/U11 with a live or
  integration test.
- Both env override and config proxy set → env wins. Already covered by `resolve`
  precedence (U2); no separate line needed.
- Proxy field present but empty (`""`) treated as no proxy. Covered by U4/U9
  (empty ⇒ `null` ⇒ direct).

## Out of scope

Things a reader may expect on this list and the one-line reason they are absent.

- Non-localhost proxies: spec says only localhost proxies are required/supported;
  non-localhost is explicitly not rejected but not tested.
- Per-provider proxy selection: spec states single active provider per run;
  out of scope.
- Global/system proxy auto-detection: explicitly disabled (FR-005), so there is no
  behavior to add — only the opt-out (U9/U11) to preserve.
- TOML config format: spec defers the same `proxy` field name to a later format;
  not part of this feature.

## Verification commands

Copied verbatim from `.specify/memory/tdd-profile.md` (detected_at `9376b03`):

- Active (non-TLS) suite: `zig build test --summary all` (green, **43 tests**, no TLS execution, ~10s run). This is the default green run for the HTTP-proxy scenario.
- Deferred (TLS) suite: `zig test src/provider/transport_tls.zig` (green, 9 tests incl. U12 — verifies the HTTPS-through-proxy CONNECT+TLS path; not collected by `tests.zig`).
- Single test: **none** — `zig test <file>` fails on `../` relative imports, and
  `zig test tests.zig --test-filter` matches nothing in this Zig 0.15.2 build
  (silent false-green). The loop runs the whole suite per cycle.
- Coverage: **kcov** (installed via `brew install kcov`; verified 2026-08-26).
  Full-suite only: `kcov --include-pattern=src/ <out> .zig-cache/o/<hash>/test` →
  HTML + `coverage.json`. Baseline 86.92% overall; `transport.zig` 66.34%.
- Mutation: **none** (no Zig mutation tool; audit uses deliberate mutants).
