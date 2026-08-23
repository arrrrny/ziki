# Implementation Plan: Proxy Config

**Branch**: `009-proxy-config` | **Date**: 2026-08-23 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/009-proxy-config/spec.md`

## Summary

Add a single `proxy` configuration setting (plus a `ZIKI_PROXY` environment override)
that, when present, routes every outbound request from ziki to the model provider
through that proxy — matching kimi's `proxy_url` behavior. When unset, requests go
directly (unchanged). System-wide/global proxy auto-detection is explicitly disabled.

The change is confined to three files: the config loader (new field), the real HTTP
transport (applies the proxy to the client), and `main.zig` (passes the value through
the existing dependency-injection seam). The provider client and the goal executor are
untouched, preserving their provider-agnostic contracts.

## Technical Context

**Language/Version**: Zig 0.15.2

**Primary Dependencies**: none (uses `std.http.Client` + `std.crypto.tls`; no third-party deps)

**Storage**: flat config file at `~/.config/ziki/config.json` (field added); no schema migration

**Testing**: `zig build test` (in-process unit tests) + a live end-to-end goal run against the user's local proxy at `http://localhost:8890`

**Target Platform**: macOS / Linux CLI (single static binary)

**Project Type**: CLI agent

**Performance Goals**: proxying must be transparent — no added latency budget beyond the proxy itself; memory footprint unaffected (proxy struct is a few words on the existing allocator)

**Constraints**: must NOT auto-detect system proxy env vars; only `localhost` proxies are required/supported for testing; single static binary, no runtime dependencies

**Scale/Scope**: one new config field; one transport responsibility; affects only the active provider's transport

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

- **I. SOLID** — PASS. Proxy handling lives solely in `HttpTransport` (SRP: transport owns connection concerns). `OpenAIProvider` and `GoalExecutor` are not edited to add proxy behavior (OCP: new behavior arrives as new code in the transport, not patches to stable modules). `GoalExecutor` still depends only on the `Transport` interface (DIP/LSP preserved — a proxied transport is behaviorally identical to a direct one).
- **II. Dependency Inversion & Interface-First** — PASS. The proxy is supplied from the composition root (`main.zig`) into the `HttpTransport` behind the existing `Transport` abstraction; no consumer reaches `std.http` directly.
- **III. Open/Closed** — PASS. No existing module is modified to "add a case"; `HttpTransport.init` gains an optional parameter and the request path gains proxy assignment.
- **IV. DRY** — PASS. Proxy URL parsing is implemented once (a single helper) and reused by the transport; config precedence logic is extended, not duplicated.
- **V. Test-First / TDD** — PASS. Tests for config loading (precedence, empty, malformed) and for proxy construction (host/port/protocol) are written before the implementation; the live goal run is the acceptance proof (SC-001).
- **Quality Gates** — PASS. Build, format, and the full test suite remain green; proxy is covered by tests written first.

No violations. Complexity Tracking table not needed.

## Project Structure

### Documentation (this feature)

```text
specs/009-proxy-config/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/
│   └── config-contract.md   # config + env surface
└── tasks.md             # Phase 2 output (speckit-tasks)
```

### Source Code (repository root)

```text
src/
├── config/config.zig        # Config.proxy field; load from JSON `proxy` + ZIKI_PROXY
├── provider/transport.zig   # HttpTransport.init(alloc, proxy?); build + apply std.http proxy
└── main.zig                # pass cfg.proxy into HttpTransport.init
```

**Structure Decision**: Small, additive change to the existing CLI layout. The proxy is a
transport-level concern, so it is owned by `HttpTransport`; configuration ownership stays in
`config.zig`; wiring stays in `main.zig` (composition root). No new modules or directories
for source — the feature is a cross-cutting setting, not a new subsystem.

## Complexity Tracking

No constitution violations. No justification required.
