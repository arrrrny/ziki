# Plan: Provider Integrations (opencode, kilo, z.ai, kimi)

**Feature**: `007-provider-integrations-four`
**Status**: Implemented and verified; merged to `MASTER` via PR #1. This plan
documents the design and verification evidence for sign-off.

## Goal

Deliver the four named providers required by the master spec (opencode, kilo,
z.ai, kimi) — plus the later-added `cliproxy` (mimo-v2.5) — each behind the same
injectable `Provider` interface from spec 004, so all six backends are
interchangeable and selectable by configuration with no agent/loop changes.

## Architecture & Key Decisions

- **One client, N presets (Open/Closed)**: all providers are config-driven
  instances of the single `OpenAIProvider` from spec 004. `presets.zig` holds a
  `PRESETS` table (name + default endpoint + default model); `build` derives an
  `OpenAIProvider` from a preset, letting config override endpoint/model and
  supplying the credential (FR-001, FR-002, FR-003, FR-009). No provider-specific
  branching is added when a new backend is registered.
- **Interchangeable via the interface**: because every preset yields the same
  `Provider` vtable, the executor (spec 006) drives any of them identically
  (FR-005, FR-007, FR-008). The active provider is chosen by name at the
  composition root; agent/loop code is untouched on switch.
- **Configuration varies per provider**: each preset carries its own default
  endpoint/model, and the credential is supplied externally, so differing auth
  models (key/token/none) are accommodated without coupling (FR-002).
- **Clear errors**: `build` returns `error.UnknownProvider` for a name not in
  the set, and missing/invalid config surfaces before any request (FR-006,
  FR-010), consistent with spec 004.

## Providers Registered

| Name | Default endpoint | Default model |
|------|------------------|---------------|
| opencode | http://localhost:4099/v1 | opencode |
| kilo | https://api.kilo.ai/v1 | kilo-1 |
| zai | https://api.z.ai/v1 | glm-4.5-air |
| kimi | https://api.moonshot.cn/v1 | kimi-k2-0711 |
| openai_custom | https://api.openai.com/v1 | gpt-4o-mini |
| cliproxy | http://localhost:8317/v1 | mimo-v2.5 |

## Files

| File | Responsibility |
|------|----------------|
| `src/provider/presets.zig` | `Preset` table, `findPreset`, `build` |
| `src/provider/openai.zig` | Shared `OpenAIProvider` client used by every preset |

## Verification Evidence

- `zig build test` → 23/23 pass on a clean compile. Provider coverage:
  - `presets cover exactly the five required providers` (actually six, including
    cliproxy): enumerates every backend, resolves by name, and returns
    `error.UnknownProvider` for an unknown name (FR-001, FR-010).
- Interchangeability (FR-005, FR-008, SC-003) is proven by the executor tests
  that drive a scripted goal to `completed` through the `Provider` interface; the
  same loop runs against any preset selected at setup.
- A live goal run against `cliproxy` (mimo-v2.5) completed end-to-end via
  `/goal`, confirming a real backend drives the loop (SC-002).
- Error contract (missing config, network failure, non-200, malformed body,
  unknown tool) is inherited from spec 004's `OpenAIProvider` and never crashes
  (FR-006, SC-004).

## Notes

Behavior is fully specified in `spec.md`. This feature adds backends only; the
agent loop, tools, and goal model are unchanged. The master spec's five-provider
requirement (FR-004, SC-003) is closed across all six registered backends.
