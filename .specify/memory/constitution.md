<!--
  SYNC IMPACT REPORT
  ==================
  Version change: 1.0.0 -> 1.1.0
  Modified principles:
    - I. SOLID Adherence (No Exceptions) -> materially expanded: each of the 5
      SOLID principles now carries an explicit IS / IS NOT and a concrete Zig
      example grounded in the ziki spec (Goal, Provider, Session, tools).
  Added sections: None (no new top-level heading; Principle I gained sub-sections).
  Removed sections: None.
  Deferred TODOs: None.
  Bump rationale: MINOR — guidance materially expanded with worked examples that
    make every SOLID principle enforceable; existing Principles II-V and Governance
    unchanged.
-->

# ziki Constitution

## Core Principles

### I. SOLID Adherence (No Exceptions)

The five SOLID principles are HARD, NON-NEGOTIABLE constraints. No deviation is
permitted for expediency, deadline pressure, or "temporary" hacks. Each principle
below states what it IS, what it IS NOT, and a concrete Zig example from this
project (ziki / Zig Goal CLI, per `specs/001-zig-goal-cli/spec.md`).

#### 1. Single Responsibility Principle (SRP)

- **IS**: Every module, type, and function has exactly ONE reason to change.
  Cohesion is mandatory; mixed concerns are forbidden.
- **IS NOT**: A "god module" that parses `/goal` input, drives turns, formats
  terminal output, manages credentials, and decides retry policy all in one place.
- **Zig example**: `goal.Goal` holds objective/status/progress only.
  `goal.GoalRepository` owns persistence (FR-006). `agent.GoalExecutor` drives
  turns (FR-002). `provider.ProviderClient` talks to the model backend. Changing
  the storage format MUST NOT require touching the executor, and vice-versa — each
  has its own single reason to change.

#### 2. Open/Closed Principle (OCP)

- **IS**: Software entities are open for extension and closed for modification.
  See Principle III for the enforcement rule.
- **IS NOT**: Editing a stable function to add `if (provider == .kilo) { ... }`
  `else if (provider == .opencode) { ... }` branches whenever a new provider or
  case appears.
- **Zig example**: Adding a sixth provider means a NEW struct implementing the
  `provider.Provider` interface, wired at the composition root. Existing provider
  code is NOT edited. New behavior arrives as new code, never as patches to what
  already ships and passes. (Enforced by Principle III.)

#### 3. Liskov Substitution Principle (LSP)

- **IS**: Any implementation of an abstraction MUST be substitutable for any other
  without altering the correctness of the consuming code.
- **IS NOT**: A provider that satisfies the `Provider` interface on paper but
  throws "unsupported operation" or returns a malformed response for methods the
  others implement — silently breaking `GoalExecutor` the moment it is swapped in.
- **Zig example**: `kimi`, `opencode`, `kilo`, `z.ai`, and `openai_custom`
  (FR-004) MUST all be behaviorally interchangeable behind `provider.Provider`.
  `GoalExecutor` MUST produce identical behavior regardless of which one is the
  active provider. A provider that quietly changes the contract is a violation, not
  a "special case".

#### 4. Interface Segregation Principle (ISP)

- **IS**: Clients MUST NOT depend on interfaces they do not use. Interfaces MUST
  be narrow and purpose-specific, never broad "kitchen-sink" contracts.
- **IS NOT**: A single fat `Agent` interface forcing `GoalExecutor` to depend on
  `drawTui()`, `playNotification()`, `sendEmail()` methods it never calls, merely
  because some other consumer needs them.
- **Zig example**: The `tool.Tool` interface exposes only `execute(args)`. The
  executor depends on `tool.Tool`, not on a broad `agent.AgentCapabilities`
  contract. `fs.FileReader` depends only on a narrow `fs.Fs` interface, not the
  full storage API. Cosmetic-things-out-of-scope (theming, notifications) stay
  OUT of the contracts the agent core must satisfy.

#### 5. Dependency Inversion Principle (DIP)

- **IS**: High-level policy MUST NOT depend on low-level details; both MUST depend
  on abstractions. See Principle II for the enforcement rule.
- **IS NOT**: `agent.GoalExecutor` directly `@import`ing and calling a concrete
  `kimi.KimiClient` (or any concrete `ProviderClient`), hard-wiring the
  high-level goal logic to one backend.
- **Zig example**: `GoalExecutor` receives a `provider.Provider` (interface/vtable)
  and a `tool.Tool` set through its init; the concrete clients are constructed at
  the composition root and injected. Cross-boundary dependencies (I/O, time,
  randomness, storage) are ALL supplied as abstractions from the outside, never
  reached directly. This is what keeps each window's memory small and swappable
  (FR-009). (Enforced by Principle II.)

### II. Dependency Inversion & Interface-First

Code MUST depend on abstractions (interfaces, traits, function pointers,
abstract APIs), never on concrete implementations. The concrete detail is
supplied from the outside (composition root / dependency injection), never
hard-wired inside the consumer.

- Every cross-boundary dependency (I/O, providers, storage, time, randomness)
  MUST be expressed as an interface that the consumer writes against.
- No unit under test MAY reach a concrete external dependency directly; it MUST
  go through its injected abstraction so it can be substituted in tests.
- Rationale: This is what makes the system testable, swappable, and memory-tunable
  without rewriting call sites.

### III. Open/Closed (Extension via New Code)

Existing, working code MUST NOT be modified to add new behavior. New behavior
MUST be delivered as NEW code that is composed in, never by editing what already
ships and passes.

- Adding a feature = adding a new module/implementation behind an existing
  interface, then wiring it at the composition root.
- Patching, "small tweaks", or branching inside stable code to support a new case
  is forbidden.
- Rationale: Modifying proven code is the primary source of regressions and
  memory/behavior drift. New code is isolated, reviewable, and reversible.

### IV. DRY (Don't Repeat Yourself)

Every piece of knowledge and every unit of logic MUST have a single,
unambiguous representation in the codebase.

- Duplicated logic (copy-pasted blocks, parallel control flow, repeated
  constants/config) MUST be extracted into one shared, tested unit.
- Near-duplication that will diverge over time MUST be consolidated or made
  parametric.
- Rationale: Duplication multiplies the cost of every future change and is a
  leading cause of inconsistent behavior.

### V. Test-First / TDD (NON-NEGOTIABLE)

Tests MUST be written BEFORE the implementation they cover. The cycle is
strictly: write a failing test -> watch it fail (RED) -> write the minimal
implementation -> watch it pass (GREEN) -> refactor -> repeat.

- No production code is committed without a corresponding failing-then-passing test.
- Tests MUST be the specification of behavior; if a requirement cannot be tested,
  the requirement is not shippable as written.
- Rationale: TDD is the only guaranteed way to prove every shippable feature is
  testable and actually tested, which is a hard project requirement.

## Quality Gates

- A change is shippable ONLY when its tests are green and the new behavior is
  covered by tests written first (per Principle V).
- Tests MUST be real (exercise behavior, not merely assert true). Tests MUST NOT
  be weakened or deleted to force a green run.
- Every PR MUST demonstrate: new tests added first, behavior implemented to make
  them pass, no violation of SOLID / DRY / Open-Closed.
- Static/structural checks (formatting, build, lint, memory budget where
  applicable) MUST pass before merge.

## Development Workflow & Review

- New behavior is delivered as new code behind interfaces (Principles II & III);
  reviewers MUST reject modifications to existing stable code made to add features.
- Reviewers MUST verify SOLID compliance, DRY compliance, and that tests were
  written before the implementation.
- Complexity MUST be justified. When in doubt, prefer the simpler, more
  testable design.
- The constitution supersedes local habits and ad-hoc practice. Conflicts are
  resolved in favor of this document.

## Governance

- This constitution is the supreme standard for how code is written in the project;
  it overrides contradictory conventions, linters defaults, and personal preference.
- Amendments require: a written rationale, a version bump per semantic versioning
  (MAJOR for removals/redefinitions, MINOR for new/expanded principles, PATCH for
  clarifications), and review sign-off.
- Every PR and review MUST confirm compliance with the current constitution;
  non-compliant code is blocked regardless of functional correctness.
- The constitution is versioned alongside the code; its version is cited in the
  changelog when it changes.

**Version**: 1.1.0 | **Ratified**: 2026-08-22 | **Last Amended**: 2026-08-22
