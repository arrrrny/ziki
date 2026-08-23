# Tasks: Proxy Config

**Input**: Design documents from `/specs/009-proxy-config/`

**Prerequisites**: plan.md (required), spec.md (required for user stories), research.md, data-model.md, contracts/

**Tests**: INCLUDED — TDD is mandated by the project constitution (Principle V) and explicitly requested. Tests are written FIRST and must fail before implementation.

**Organization**: Tasks are grouped by user story to enable independent implementation and testing.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (US1, US2)
- Include exact file paths in descriptions

## Path Conventions

- **Single project**: `src/` at repository root; in-process tests live in the same files as the code (`test "..."` blocks) and run via `zig build test`.

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Confirm the existing project is the target; nothing to scaffold.

- [ ] T001 Confirm feature branch `009-proxy-config` checked out and design docs (plan.md, research.md, data-model.md, contracts/config-contract.md, quickstart.md) present in `specs/009-proxy-config/`

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Config gains the `proxy` field that every downstream story depends on.

**⚠️ CRITICAL**: No user story work can begin until this phase is complete.

- [ ] T002 [US1] [TDD] Write config test FIRST in `src/config/config.zig`: load a config JSON containing `"proxy"` and assert `Config.proxy` equals it; load with `ZIKI_PROXY` env set and assert env wins; load with no proxy key and assert `proxy` is `""`. MUST fail before implementation.
- [ ] T003 [US1] [TDD] Write config test FIRST in `src/config/config.zig`: malformed `proxy` value still parses as a string (parsing/validation happens at transport init, not here) — assert the field is carried verbatim so the transport can reject it at startup.
- [ ] T004 [US1] Add `proxy: []const u8` to `Config` and `FileOverrides` in `src/config/config.zig`; load from JSON key `proxy`; override with `ZIKI_PROXY` env when set (same precedence as `ZIKI_PROVIDER`/`ZIKI_ENDPOINT`/`ZIKI_MODEL`/`ZIKI_API_KEY`); default `""`.

**Checkpoint**: Config exposes `proxy`; env-over-file precedence holds. Transport work can now begin.

---

## Phase 3: User Story 1 - Route requests through a configured localhost proxy (Priority: P1) 🎯 MVP

**Goal**: When `proxy` is configured, every outbound provider request is routed through it; the goal completes with the same outcome as a direct connection.

**Independent Test**: `ZIKI_PROXY="http://localhost:8890" ziki /goal "print ZIKI_PROXY_OK" --criterion "output contains ZIKI_PROXY_OK"` → `status: completed`, request traversed the live proxy (quickstart Scenario C).

### Tests for User Story 1 (TDD — write FIRST, ensure they FAIL)

- [ ] T005 [P] [US1] [TDD] Write transport test FIRST in `src/provider/transport.zig`: `parseProxy`/`makeProxy` of `"http://localhost:8890"` yields `protocol == .plain`, `host == "localhost"`, `port == 8890`, `supports_connect == true`; `"https://proxy:3128"` yields `.tls`/port 3128; malformed input returns an error.
- [ ] T006 [P] [US1] [TDD] Write transport test FIRST in `src/provider/transport.zig`: a `HttpTransport` built with `proxy == null` exposes a `null` client proxy field (proves we never call `initDefaultProxies` → system proxy ignored); a transport built with a valid proxy exposes a non-null proxy with the correct host/port.

### Implementation for User Story 1

- [ ] T007 [US1] Implement `makeProxy(alloc, url) !?*std.http.Client.Proxy` in `src/provider/transport.zig` using `std.Uri` (scheme→protocol, host, port default 80/443, `authorization = null`, `supports_connect = true`); return error on unparseable input.
- [ ] T008 [US1] Change `HttpTransport.init(alloc, proxy: ?[]const u8) !HttpTransport` in `src/provider/transport.zig` to parse the proxy at init (startup, before any request) and store `proxy: ?*std.http.Client.Proxy`; return the parse error so `main.zig` can fail fast (FR-007).
- [ ] T009 [US1] In `HttpTransport.request` (`src/provider/transport.zig`), after creating the per-request `std.http.Client`, assign `client.http_proxy = self.proxy` and `client.https_proxy = self.proxy` when set; never call `initDefaultProxies` (FR-005).
- [ ] T010 [US1] Pass `cfg.proxy` into the transport in `src/main.zig` `runGoal`: `var transport = HttpTransport.init(alloc, cfg.proxy) catch { emitErr("invalid proxy URL"); return; };`

**Checkpoint**: US1 functional. A goal with a valid proxy set completes identically to a direct run; malformed proxy aborts at startup.

---

## Phase 4: User Story 2 - Configure proxy without global/system proxy support (Priority: P2)

**Goal**: The proxy is a simple config value; ziki never auto-detects system-wide proxy settings.

**Independent Test**: `http_proxy="http://127.0.0.1:9" ziki /goal "print ZIKI_NO_SYS_PROXY" --criterion "output contains ZIKI_NO_SYS_PROXY"` completes directly (quickstart Scenario E). Covered by T006 (null client proxy) + this live scenario.

### Implementation for User Story 2

- [ ] T011 [US2] Confirm `src/provider/transport.zig` never references `initDefaultProxies` and `HttpTransport.request` only sets proxy fields when `self.proxy != null`; add a comment asserting the deliberate opt-out of system proxy auto-detection (FR-005). No new branching in provider/executor code (OCP).

**Checkpoint**: US2 functional. System proxy env vars are ignored unless `proxy` is explicitly configured.

---

## Phase 5: Polish & Cross-Cutting Concerns

- [ ] T012 [P] Document the `proxy` config field and `ZIKI_PROXY` env override in `README.md` (add to the config block; note system proxy auto-detection is disabled).
- [ ] T013 Run `zig build test --summary all` and confirm all tests green (no regression).
- [ ] T014 Live-verify quickstart scenarios B, C, D, E: direct run, proxied run through `http://localhost:8890`, malformed-proxy fast-fail, and system-proxy-ignored.
- [ ] T015 Commit, open PR against MASTER, merge, and pull.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — start immediately.
- **Foundational (Phase 2)**: Depends on Setup — BLOCKS all user stories.
- **US1 (Phase 3)**: Depends on Foundational (needs `Config.proxy`).
- **US2 (Phase 4)**: Depends on US1 (shares the transport's proxy handling); independently testable via the null-proxy test + live scenario.
- **Polish (Phase 5)**: Depends on US1 + US2.

### User Story Dependencies

- **US1 (P1)**: After Foundational. No dependency on other stories.
- **US2 (P2)**: After US1. Independently testable (system-proxy-ignored scenario does not need a real proxy).

### Within Each User Story

- Tests MUST be written and FAIL before implementation (TDD).
- Config field (Phase 2) before transport wiring (Phase 3).
- Core implementation before live validation (Phase 5).

### Parallel Opportunities

- T005 and T006 (transport tests) can be written together.
- T007/T008/T009 (transport implementation) are sequential within `transport.zig` but T012 (README) is parallelizable with implementation.

---

## Parallel Example: User Story 1

```bash
# Write both transport tests first (TDD):
Task T005: "parseProxy yields correct protocol/host/port"
Task T006: "HttpTransport null vs configured proxy field"

# Then implement:
Task T007: "makeProxy helper"
Task T008: "HttpTransport.init(alloc, proxy?)"
Task T009: "apply proxy in request"
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Phase 1 Setup → T001
2. Phase 2 Foundational → T002..T004 (config field + tests)
3. Phase 3 US1 → T005..T010 (TDD tests, then transport + wiring)
4. **STOP and VALIDATE**: `zig build test` green + live proxied goal (quickstart C)
5. Demo/merge if ready

### Incremental Delivery

1. Setup + Foundational → config exposes `proxy`
2. US1 → proxied requests work (MVP)
3. US2 → system proxy auto-detection disabled
4. Polish → docs + full live validation + PR

---

## Notes

- TDD is non-negotiable (constitution Principle V): every implementation task has a preceding test task written first.
- The provider client (`openai.zig`) and executor are NOT modified — proxy is purely a transport concern (SRP/OCP/DIP).
- Keep the change minimal: one config field, one transport responsibility, one wiring line.
