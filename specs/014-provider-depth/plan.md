# Implementation Plan: [Lane B] Provider depth

**Branch**: `014-provider-depth` | **Spec**: `specs/014-provider-depth/spec.md` | **Issue**: #17

## Summary
Four provider-layer additions, all additive: (1) per-preset request-shape + response-fixture tests via a capturing transport, (2) `FinishReason.unknown` + executor surfacing of `length`/cutoff/unknown, (3) 401/403 → distinct credential errors, fail-fast (no retry), executor `.blocked` with actionable text, (4) 400/404 → `ModelNotFound` + models-list probe surfaced through an optional `Provider.errorHint()` vtable method.

## Technical Decisions
- **D1 — One client, tests per preset**: presets stay config-only (OCP); `src/provider/presets_test.zig` adds a `CapturingTransport` and loops the four hosted presets with per-backend fixtures (shapes only; no secrets).
- **D2 — Unknown ≠ stop**: `FinishReason.fromJson` maps unrecognized strings to a new `.unknown` instead of `.stop`; the existing pinned test asserting `.stop` is updated deliberately (spec-driven change, logged). The executor adds a job-report note for `.length`, `.tool_calls`-without-calls, and `.unknown`; loop flow unchanged (deterministic).
- **D3 — Non-transient errors**: `completeInterruptible` returns immediately (no retry/backoff) for `Unauthorized | Forbidden | ModelNotFound`. The executor maps them to `.blocked` via `finishProviderBlocked`, embedding the hint for model rejections.
- **D4 — Hint transport**: errors cannot carry payloads across the vtable, so `Provider.VTable` gains an optional `error_hint` fn (default null; fakes unaffected). `OpenAIProvider` stores the probe result (owned, replaced per probe) and serves it.

## Data Flow
`complete()` → transport → status: 401/403 → credential error; 400/404 → `GET {endpoint}/models` probe → hint stored → `ModelNotFound`; executor → `.blocked` + hint in progress/report.
