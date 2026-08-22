# Tasks: Provider Interface & OpenAI-Compatible Reference

**Input**: Design documents from `/specs/004-provider-interface-openai/`
**Prerequisites**: `spec.md`, `plan.md`

**Tests**: Required — the constitution (TDD, Principle V) mandates tests FIRST.
The implementation was built test-first; every interface boundary ships with an
independent test (mock transport / fake provider, no live network).

**Organization**: Tasks grouped by user story (US1–US3 from spec.md).

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)

## Phase 1: Setup (Shared Interface)

- [X] T001 Define the `Provider` vtable interface and the request/response
  types (`CompletionRequest`, `ChatResponse`, `ToolCall`, `ToolSpec`,
  `ChatMessage`, `FinishReason`) in `src/provider/provider.zig` (FR-001, FR-002,
  FR-003).

---

## Phase 2: User Story 1 — Send a conversation, get a completion (P1)

- [X] T002 [P] [US1] Test (RED) `parseResponse maps tool_calls`,
  `parseResponse tolerates missing tool_calls/finish_reason`,
  `buildRequestBody embeds raw schema`: assert the request carries system
  prompt + history + tool descriptions and the parsed completion exposes text /
  tool calls / finish. Then implement `openai.zig` to satisfy them (FR-004,
  FR-005).

## Phase 3: User Story 2 — Swap the backend (P1)

- [X] T003 [P] [US2] Test (RED) `FakeProvider steps through script and clones`
  and `FlakyProvider fails first N then succeeds`: drive the agent loop through
  the interface recording inputs, no network. Then implement `fake.zig`
  (FR-006, SC-004).
- [X] T004 [P] [US2] Test (RED) `HttpTransport type-checks via FakeTransport
  shape`: prove the HTTP send is behind a `Transport` boundary so tests inject a
  fake and assert the exact request (FR-005). Then implement `transport.zig`.

## Phase 4: User Story 3 — Configure the reference provider (P2)

- [X] T005 [P] [US3] Implement `presets.zig` to build the active provider from
  config and enumerate exactly the five required providers (FR-007,
  FR-008). Covered by `presets cover exactly the five required providers` test.

---

## Phase 5: Polish & Cross-Cutting

- [X] T006 Verify `zig build test` — provider interface, parse, transport,
  presets, and fake tests pass; FR-001..FR-010 and SC-001..SC-005 satisfied.
  Error paths (missing config, non-200, malformed body, limit, unknown tool)
  return structured errors without crashing (FR-009, FR-010).

## Dependencies & Execution Order

- T001 (interface + types) blocks all user stories.
- US1 (T002), US2 (T003, T004), US3 (T005) are independent files → parallel.
- T006 is the final verification gate.

## Notes

- The agent (executor) depends only on `Provider.complete`; concrete clients are
  injected at the composition root (verified by the `FakeProvider` executor
  test).
- The remaining four named providers (opencode, kilo, z.ai, kimi) + cliproxy
  implement this same interface and are covered by spec 007.
