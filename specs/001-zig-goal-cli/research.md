# Research: Zig Goal CLI (ziki)

Resolution of the technical unknowns from the plan's Technical Context. Every
item below resolves a NEEDS CLARIFICATION or a dependency best-practice question.
Findings are grounded in Zig 0.15.2 stdlib (verified on this machine) and the
project constitution.

## R1. How does ziki talk to model providers?

- **Decision**: Use `std.http.Client` (HTTPS via `std.crypto.tls`) directly. No
  third-party HTTP library.
- **Rationale**: Verified present in Zig 0.15.2 (`lib/std/http/Client.zig`,
  `lib/std/crypto/tls/Client.zig`). Zero deps keeps the per-window memory
  footprint minimal (FR-009 / SC-002) and avoids ABI/version churn.
- **Alternatives considered**: (a) `libcurl` binding — rejected: C dep, larger
  binary, more memory. (b) Hand-rolled TCP+TLS only for one provider — rejected:
  `std.http.Client` already does this.
- **Consequence**: The HTTP transport is wrapped behind a `transport.Transport`
  interface so it can be faked in tests (DIP, Principle II).

## R2. Which provider protocol do the five required providers share?

- **Decision**: All five (opencode, kilo, z.ai, kimi, OpenAI-compatible custom)
  are OpenAI-compatible Chat Completions APIs. One concrete client
  (`provider.openai`) implements the protocol; the five are **presets** that set
  endpoint + default model (FR-004).
- **Rationale**: opencode, kilo, z.ai, kimi all expose OpenAI-compatible
  endpoints. A single client + config presets satisfies FR-004 with zero
  per-provider branching (OCP, Principle III) and keeps all five
  behaviorally interchangeable (LSP, Principle I.3).
- **Alternatives considered**: A distinct client per provider — rejected:
  duplicated protocol logic (DRY, Principle IV) and branching (OCP violation).

## R3. How are tools modeled so the executor never depends on concretes?

- **Decision**: A `tool.Tool` interface (`execute(args_json) -> ToolResult`),
  implemented by read / edit / search / bash. The executor depends only on the
  interface and a list of tools (ISP, Principle I.4). Filesystem access goes
  through an `fs.Fs` interface so tools are testable without touching disk
  (DIP, Principle II).
- **Rationale**: Matches Kimi tool parity (FR-007) and keeps the executor free
  of I/O details, which is what makes memory small and tests fast.

## R4. How is autonomous completion decided?

- **Decision**: Two mechanisms. (1) The model signals completion via a stop
  condition in its final message. (2) If the user supplied `--criterion`, the
  executor asks the model a bounded yes/no "is the criterion met?" after each
  final answer; completion is recorded when the model answers yes. A `FakeProvider`
  in tests returns scripted completions so the loop is verified deterministically.
- **Rationale**: Mirrors Kimi `/goal` (spec Assumptions) and is fully testable
  without a live model.

## R5. How is goal state persisted and resumed?

- **Decision**: `Goal` serialized to JSON (`.ziki/goal.json`) via `std.json`. A
  `GoalRepository` interface (`save`/`load`/`list`) with an `FsGoalRepository`
  impl using the injected `Fs`. State is written after every turn (FR-006).
- **Rationale**: JSON + files needs no DB; resume = load + continue loop. Plain
  file is the simplest durable store and keeps memory flat.

## R6. How is memory kept bounded across 20 windows?

- **Decision**: Manual memory (Zig, no GC). Per-turn arena allocator reset after
  each provider round-trip; bounded message history with compaction when it
  exceeds a configurable token cap; no process-global caches. The 008 slice adds
  the formal 20-window budget measurement; the architecture here is designed to
  pass it.
- **Rationale**: The rewrite's entire purpose is FR-009 / SC-002; the language
  choice is the lever, and the design avoids the per-window bloat sources
  (runtimes, retained history, global state).

## R7. How are tests run and what is the e2e proof?

- **Decision**: `zig build test` aggregates all `_test.zig`. The end-to-end proof
  is an integration test in `agent/executor_test.zig` that runs `GoalExecutor`
  with `FakeProvider` + real `read`/`edit`/`bash` tools against a temp dir and
  asserts the goal reaches `completed` with the expected artifact produced. A
  real-provider smoke test is gated behind an env var (`ZIKI_API_KEY`) so CI
  without credentials does not fail.
- **Rationale**: TDD mandated (Principle V); the fake-backed integration test
  satisfies "a goal is completed end-to-end" without network (SC-001 mechanism),
  while the env-gated test proves the real client path.
