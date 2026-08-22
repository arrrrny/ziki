# Implementation Plan: Zig Goal CLI (ziki)

**Branch**: `001-zig-goal-cli` | **Date**: 2026-08-22 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/001-zig-goal-cli/spec.md`

## Summary

A memory-light, Zig-native rewrite of Kimi's `/goal` autonomous agent. The MVP
delivers a terminal CLI that accepts `/goal <objective>` (optionally with an
explicit completion criterion), drives an autonomous multi-turn loop using a
model provider and a set of coding tools (read / edit / search / bash), and
persists goal state so it survives restart. All five required providers
(opencode, kilo, z.ai, kimi, OpenAI-compatible custom) are supported through a
single OpenAI-compatible client driven by provider presets (no per-provider
branching). The design is interface-first (DIP) and TDD, per the constitution,
so every behavior is covered by a test written before its implementation.

## Technical Context

**Language/Version**: Zig 0.15.2 (hard constraint, see spec Assumptions).

**Primary Dependencies**: None beyond Zig stdlib. Verified available in 0.15.2:
`std.http.Client` + `std.crypto.tls` (HTTPS to providers, no third-party HTTP
lib), `std.json` (request/response + goal-state persistence), `std.Uri`,
`std.fs`, `std.process`, `std.mem.Allocator`. Zero external packages keeps the
per-window memory budget small (FR-009 / SC-002).

**Storage**: Plain files. Goal state persisted as JSON in the session working
directory (`.ziki/goal.json`) or a configured path (FR-006). Config loaded from
`~/.config/ziki/config.json` and per-session overrides (FR-005).

**Testing**: Zig built-in test runner via `zig build test` (aggregates every
`_test.zig`). TDD is mandated by the constitution (Principle V): failing test
first, then minimal implementation. A `fake` module supplies in-memory
`Provider`, `Tool`, and `Fs` implementations so the full loop is tested with no
network and no real filesystem.

**Target Platform**: macOS / Linux terminal (x86_64 + aarch64). Single static
binary, no runtime/GC.

**Project Type**: CLI (interactive agent session; visual design explicitly out
of scope per spec).

**Performance Goals**: Goal loop latency bounded by provider round-trip; no
per-turn memory growth (arena/reset allocators). SC-002: 20 concurrent windows
<= ~1.25 GB total (measured in the 008 follow-up, architecture designed for it).

**Constraints**: < 200 MB per idle window; bounded message history with
compaction when context grows (spec edge case); fail-fast clear errors when no
provider is configured (FR-010).

**Scale/Scope**: 5 providers (config presets over one client). Tools: read,
edit, grep, bash. Memory harness (008) and the 4 extra provider presets' formal
verification (007) are explicitly-scoped follow-up slices; the architecture
ships them for free but this plan's shippable milestone is the goal loop.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Plan compliance | Status |
|-----------|-----------------|--------|
| I. SOLID (SRP) | `goal.Goal` (data) / `GoalRepository` (persistence) / `GoalExecutor` (loop) / `Provider` (model I/O) / `Tool` (effects) are separate modules, each one reason to change. | PASS |
| I. SOLID (OCP) | New provider = new preset entry, not edited branches. New tool = new `Tool` impl composed at root. | PASS |
| I. SOLID (LSP) | All five providers interchangeable behind `provider.Provider`; all tools behind `tool.Tool`. | PASS |
| I. SOLID (ISP) | `Tool` exposes only `execute`; `GoalExecutor` depends on narrow `Provider`/`Tool`/`GoalRepository`/`Fs` interfaces, never a fat contract. | PASS |
| II. DIP / Interface-First | Every cross-boundary dep (provider, transport, fs, clock, rng, repo) is an injected interface/vtable. No unit reaches a concrete external dep directly. | PASS |
| III. Open/Closed | Behavior added as new code behind interfaces, wired at composition root (`src/main.zig`). | PASS |
| IV. DRY | Shared: message types, JSON schemas, prompt assembly, allocator policy, criterion evaluation. No duplicated control flow. | PASS |
| V. TDD | Every module ships a `_test.zig` written before its implementation; `zig build test` is the gate. | PASS |

No gate violations. No complexity-tracking exceptions required.

## Project Structure

### Documentation (this feature)

```text
specs/001-zig-goal-cli/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/           # Phase 1 output
│   ├── cli-commands.md
│   ├── provider-interface.md
│   ├── tool-interface.md
│   └── goal-state-schema.md
└── tasks.md             # Phase 2 output (/skill:speckit-tasks)
```

### Source Code (repository root)

```text
build.zig                      # exe + `zig build test` step
src/
├── main.zig                  # composition root: config -> provider -> tools -> repo -> executor -> CLI loop
├── cli/
│   ├── cli.zig               # slash-command parser (/goal, /stop, /provider, /status)
│   └── cli_test.zig
├── agent/
│   ├── executor.zig          # GoalExecutor: autonomous turn loop (FR-002/003/008)
│   └── executor_test.zig     # drives full loop with fake provider + real tools
├── provider/
│   ├── provider.zig          # Provider vtable + ChatMessage/Role/ChatResponse/ToolCall types
│   ├── openai.zig            # OpenAI-compatible concrete client (real HTTP) — reference (004)
│   ├── openai_test.zig       # tests via fake Transport
│   ├── transport.zig         # Transport interface (DI) + HttpTransport (std.http.Client)
│   ├── fake.zig              # FakeProvider (deterministic, scripted) for tests/e2e
│   └── presets.zig           # 5 provider presets (opencode/kilo/z.ai/kimi/openai_custom)
├── tool/
│   ├── tool.zig              # Tool interface + ToolResult
│   ├── read.zig  edit.zig  search.zig  bash.zig
│   └── tool_test.zig
├── goal/
│   ├── goal.zig              # Goal value type (objective, criterion, status, budgets, timestamps)
│   ├── goal_test.zig
│   ├── repository.zig        # GoalRepository interface + FsGoalRepository (JSON)
│   └── repository_test.zig
├── fs/
│   └── fs.zig                # Fs interface + RealFs + FakeFs (DI for tools/repo)
└── config/
    ├── config.zig            # load provider/model/endpoint/key (FR-005)
    └── config_test.zig
```

**Structure Decision**: Single CLI project (Option 1). Interface modules (`provider`,
`tool`, `goal`, `fs`) are the dependency-inverted boundaries; `agent/executor.zig`
is the high-level policy; `src/main.zig` is the composition root. Tests live next
to sources as `_test.zig` and run via `zig build test`. This matches the spec's
decomposition into sub-specs 002–008 (dispatcher, tool layer, provider, goal
state, execution loop, providers, runtime).

## Complexity Tracking

No violations. (Table intentionally empty — constitution gate passed cleanly.)
