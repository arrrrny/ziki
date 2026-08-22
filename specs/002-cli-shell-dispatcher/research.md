# Research: CLI Shell Dispatcher

**Feature**: 002-cli-shell-dispatcher
**Date**: 2026-08-22

The spec is fully specified and the project constitution already prescribes the
architecture (SOLID, DIP, TDD). There are no open `NEEDS CLARIFICATION` markers,
so this document records the resolved design decisions rather than external
research. All decisions are grounded in Zig 0.15.2 stdlib and the existing
codebase patterns (the `provider.Provider` and `tool.Tool` vtable interfaces
already used in `src/provider/` and `src/tool/`).

---

## Decision 1 — No third-party dependencies

**Decision**: Implement the shell with the Zig standard library only.
**Rationale**: The entire project exists to slash the memory footprint of a
TypeScript agent. Pulling in an argument-parsing crate (e.g. `clap`,
`zig-args`) adds a dependency and a generic machinery we do not need for five
commands — and we need a *custom, injectable* parser so it can be unit-tested
without a terminal.
**Alternatives considered**: `clap` / `zig-args` — rejected; overkill, adds a
dep, and would fight the DI/testability requirement. Hand-rolled tokenization is
trivial for this shape of input.

## Decision 2 — Dispatcher storage

**Decision**: `std.StringArrayHashMap(Handler)` keyed by command name.
**Rationale**: O(1) lookup by command, DI-friendly (store interface values),
and trivially testable with fake handlers. Registration is the only mutation
point.

## Decision 3 — Handler is a vtable interface

**Decision**: `Handler { ctx: *anyopaque, vtable: *const VTable { handle: fn } }`
mirroring `provider.Provider` / `tool.Tool` already in the repo.
**Rationale**: Consistency with the existing boundary style; zero-cost
indirection; handlers are substitutable in tests (LSP) and swapped at the
composition root (DIP). A handler receives an `Intent` and returns a `Result`.

## Decision 4 — Intent shape

**Decision**: `Intent { command: []const u8, args: []const u8, raw: []const u8 }`.
`command` is the name after `/`; `args` is the **raw remainder** (trimmed) after
the command; `raw` is the original line.
**Rationale**: Keeps the dispatcher command-agnostic. Command-specific argument
parsing (e.g. `/goal`'s `--criterion` / `--provider` flags) is the **handler's**
job, never the dispatcher's. This is what satisfies SC-005 (dispatcher contains
zero command behavior) and DIP. The dispatcher only splits `<command> <rest>`.

## Decision 5 — Non-slash lines

**Decision**: A line without a leading `/` produces an `Intent` with
`command = ""` (empty) and `args = <text>`. The dispatcher routes `""` to an
optional default handler if one is registered; otherwise it is a no-op.
**Rationale**: Satisfies FR-010 without special-casing in the dispatcher — the
dispatcher simply looks up the key `""`. No mis-parse as a slash command.

## Decision 6 — Malformed / empty / unknown handling

**Decision**:
- Empty or whitespace-only line → no intent, no dispatch (no-op).
- Malformed (`/` with no name, or invalid characters) → parser returns a
  dedicated error; the REPL prints the message and continues.
- Valid format but no registered handler (unknown command) → dispatcher returns
  an "unknown command" `Result` and invokes **no** handler.
**Rationale**: FR-008 / FR-009 / SC-004 — clear, actionable messages, no crash,
no handler side effects.

## Decision 7 — Duplicate registration

**Decision**: `register(command, handler)` rejects a second registration of the
same command (returns an error).
**Rationale**: Edge case from the spec; keeps routing unambiguous.

## Decision 8 — Injected I/O

**Decision**: The REPL takes an injected line reader (e.g. `std.Io.Reader`) and
an output sink. Scripted tests feed an in-memory reader and capture output.
**Rationale**: FR-001 / FR-007 / SC-003 — input source and output sink are
interchangeable so the engine is driven and asserted without a human at the
keyboard.

## Out of scope

The actual behavior of `/goal` and `/provider` is owned by later specs. This
feature only guarantees correct parsing and routing to whatever handler is
registered.
