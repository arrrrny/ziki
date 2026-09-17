# Feature Specification: Provider depth — per-provider mock tests, finish handling, credential errors

**Feature Branch**: `014-provider-depth` | **Issue**: [#17](https://github.com/arrrrny/ziki/issues/17) (Lane B) | **Created**: 2026-09-15

**Input**: Issue #17 verbatim tasks (audit baseline: spec 004 strict 20%, spec 007 strict 10%).

## User Scenarios & Testing *(mandatory)*

### US1 — Per-provider mock endpoint tests (P1)
**AS-1**: For each hosted preset (kilo, zai, kimi, openai_custom), a capturing `FakeTransport` records the request: URL is `<preset-endpoint>/chat/completions`, `authorization: Bearer <key>`, body carries the preset's model id and embeds tool schemas raw. **AS-2**: Each backend's recorded response shape (one fixture per provider, no secrets) parses to the same `ChatResponse` fields.

### US2 — finish_reason handling (P1)
**AS-1**: `length` → truncation is surfaced (job-report skip note), not treated as a complete stop. **AS-2**: `tool_calls` without tool calls (cutoff mid-call) → surfaced. **AS-3**: Unknown finish_reason values map to a distinct `.unknown` state and are surfaced — never silently `.stop`.

### US3 — Credential validation (P1)
**AS-1**: 401 → `error.Unauthorized`, 403 → `error.Forbidden` (distinct, actionable; no retry burn). **AS-2**: The executor finishes the goal `.blocked` with a clear message naming credentials/quota; **no key material appears in any message**.

### US4 — Model-id mismatch reporting (P2)
**AS-1**: A gateway rejection of the model id (400/404) → `error.ModelNotFound` plus a models-list probe (`GET <endpoint>/models`). **AS-2**: The executor's blocked status includes the gateway's available-models hint when the probe succeeds.

## Requirements
- **FR-001**: Provider request shape per preset is pinned by tests (auth header form, model id placement, tool schema encoding).
- **FR-002**: `FinishReason` distinguishes `stop | tool_calls | length | unknown`; the executor surfaces non-terminal finish reasons as job-report notes.
- **FR-003**: Credential and model rejections are non-transient (fail fast, no retry).
- **FR-004**: The models-list probe result is reachable on the error path via an optional `Provider.errorHint()`; no key material in any error text.
- **FR-005**: No transport changes; provider change is additive.

## Success Criteria
- SC-001: `zig build test` green; fixture-driven tests per hosted provider preset.
- SC-002: Fixtures contain no secrets (redacted tokens, real shapes).
