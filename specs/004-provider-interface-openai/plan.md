# Plan: Provider Interface & OpenAI-Compatible Reference

**Feature**: `004-provider-interface-openai`
**Status**: Implemented and verified; merged to `MASTER` via PR #1. This plan
documents the design and verification evidence for sign-off.

## Goal

Give the agent a single injectable `Provider` interface (Dependency
Inversion) plus one working implementation — an OpenAI-compatible client that
sends a conversation + tool descriptions and parses the standard response
(including tool calls). The agent depends only on the interface; a fake
provider drives the loop in tests with zero network access.

## Architecture & Key Decisions

- **Injectable interface (DIP)**: `Provider` is a vtable struct
  (`ctx` + `VTable{ complete, name }`). The executor calls only
  `Provider.complete(alloc, req)` and never references a concrete client
  (FR-001, FR-002).
- **Request/response contract**: `CompletionRequest { messages, tools,
  budget_tokens }` → `ChatResponse { message, finish_reason }`. Tool calls
  surface as `ChatMessage.tool_calls: []ToolCall` with `name` + `arguments_json`
  so the agent can execute them via the Tool layer (FR-003, FR-004).
- **OpenAI-compatible reference** (`openai.zig`): `buildRequestBody` serializes
  the conversation + tool JSON schemas; `parseResponse` maps the standard shape
  (text, `tool_calls`, or `finish_reason`) into `ChatResponse`, tolerating
  missing fields (FR-004, FR-005).
- **Transport boundary** (`transport.zig`): HTTP send is behind a `Transport`
  interface so tests inject a `FakeTransport` and assert the exact request body
  and the parsed response with no live network (FR-005, FR-006).
- **Fake provider** (`fake.zig`): steps through a scripted completion sequence
  and records inputs; `FlakyProvider` simulates transient failures so the agent
  retry path is exercised (FR-006, SC-004).
- **Presets** (`presets.zig`): builds the active provider from config and
  enumerates exactly the five required providers (opencode, kilo, z.ai, kimi,
  openai_custom) + the later-added cliproxy (FR-007). Configuration errors are
  reported before any request (FR-008).

## Files

| File | Responsibility |
|------|----------------|
| `src/provider/provider.zig` | `Provider` vtable + request/response types |
| `src/provider/transport.zig` | `Transport` boundary + `HttpTransport` |
| `src/provider/openai.zig` | OpenAI-compatible client (request build + parse) |
| `src/provider/fake.zig` | `FakeProvider` / `FlakyProvider` for tests |
| `src/provider/presets.zig` | Provider registry / config-driven builder |
| per-module `*_test` blocks | Interface, parse, transport, presets, fake |

## Verification Evidence

- `zig build test` → 23/23 pass on a clean compile. Provider coverage:
  - `Role/FinishReason json mapping` (provider.zig)
  - `parseResponse maps tool_calls`, `parseResponse tolerates missing
    tool_calls/finish_reason`, `buildRequestBody embeds raw schema` (openai.zig)
  - `HttpTransport type-checks via FakeTransport shape` (transport.zig)
  - `presets cover exactly the five required providers` (presets.zig)
  - `FakeProvider steps through script and clones`, `FlakyProvider fails first
    N then succeeds` (fake.zig)
- The executor test drives a full goal turn using `FakeProvider`/fake provider
  with no network, proving backend swap-ability (SC-001, SC-004).
- Error paths (missing config, non-200, malformed body, limit, unknown tool)
  are mapped to structured errors so the agent never crashes (FR-009, FR-010).

## Notes

Behavior is fully specified in `spec.md`. The other four named providers
(opencode, kilo, z.ai, kimi) plus cliproxy implement the same interface and are
covered by spec 007.
