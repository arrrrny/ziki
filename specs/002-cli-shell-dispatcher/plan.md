# Implementation Plan: CLI Shell Dispatcher

**Branch**: `002-cli-shell-dispatcher` | **Date**: 2026-08-22 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `specs/002-cli-shell-dispatcher/spec.md`

## Summary

A command-line shell layer that turns raw terminal input into structured
command intents and routes each intent to an injected handler. The dispatcher
contains **zero command-specific logic** — it only parses and routes. Handlers
(e.g. `goal`, `stop`, `provider`, `goals`, `help`) are supplied from the outside
via a vtable interface, so they are unit-testable without a live agent. The same
engine runs as an interactive REPL or off a scripted/in-memory input stream,
which is what makes parsing and dispatch assertable in isolation. This is the
foundational layer every later feature (goal execution, providers, tools) plugs
into.

## Technical Context

- **Language/Version**: Zig 0.15.2
- **Primary Dependencies**: Zig standard library only (no third-party deps). Keeps
  the memory footprint flat, which is the entire point of ziki.
- **Storage**: N/A — in-memory parsing and routing; no persistence in this feature.
- **Testing**: Zig built-in test runner (`zig build test`). Tests are the
  specification (Principle V / TDD).
- **Target Platform**: Native terminal binary (macOS / Linux); stdin/stdout or an
  injected stream.
- **Project Type**: CLI, delivered as a `src/shell/` module consumed by `main.zig`.
- **Performance Goals**: O(n) per line, no heap allocation on the happy path where
  feasible; sub-millisecond parse per line. Parsing is not a bottleneck.
- **Constraints**: Low memory (allocator injected, no global state); Dependency
  Inversion (handlers + I/O injected); test-first.
- **Scale/Scope**: Five initial commands, unbounded extensibility via registration.
  Later features register their own handlers against this same dispatcher.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Verdict | Why |
|-----------|---------|-----|
| SRP | PASS | Dispatcher = routing only. Parser = its own unit. Each handler = its own unit. One reason to change each. |
| OCP | PASS | New command = new registered Handler; dispatcher code is untouched. |
| LSP | PASS | Any Handler impl is substitutable behind the interface; dispatcher behavior is identical regardless of which handler is wired. |
| ISP | PASS | Handler interface is narrow (`handle(alloc, intent) -> Result`); REPL depends only on what it calls. |
| DIP | PASS | Dispatcher depends on the Handler interface; concrete handlers and I/O are injected at the composition root. This is the feature's hard requirement. |
| TDD | PASS | Tests written before implementation; tests encode the behavior. |
| DRY | PASS | Single tokenizer, single dispatcher, single routing map. |

No violations → Complexity Tracking not required.

## Project Structure

### Documentation (this feature)

```text
specs/002-cli-shell-dispatcher/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/
│   └── cli-commands.md  # Phase 1 output
└── tasks.md             # Phase 2 output (speckit-tasks)
```

### Source Code (repository root)

```text
src/shell/
├── intent.zig      # Intent + Result types
├── handler.zig     # Handler vtable interface
├── parser.zig      # parseLine -> Intent (no side effects)
├── dispatcher.zig  # Dispatcher: register + dispatch
├── repl.zig        # REPL loop over injected reader/writer
└── shell_test.zig  # unit tests (parser, dispatcher, scripted REPL)

main.zig            # composition root: build Dispatcher, register handlers,
                   # run REPL (refactored to use src/shell instead of inline dispatch)
```

**Structure Decision**: Single CLI project. A new `src/shell/` module owns the
dispatcher core (parser, dispatcher, handler interface, REPL). `main.zig`
becomes the composition root that registers the concrete handlers and starts the
REPL, removing the ad-hoc dispatch currently inline in `main.zig`. Tests live
beside the module (pulled in by `tests.zig`) so parsing, dispatch, and the REPL
are unit-tested with fake handlers and scripted input — no live agent required.

## Complexity Tracking

No constitution violations. Nothing to justify.
