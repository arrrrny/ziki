# Data Model: CLI Shell Dispatcher

**Feature**: 002-cli-shell-dispatcher

Entities involved in parsing and dispatch. All are plain Zig structs; no
persistence in this feature.

## Intent

The parsed result of one input line.

| Field | Type | Notes |
|-------|------|-------|
| `command` | `[]const u8` | Command name after `/`. Empty (`""`) for non-slash lines. Non-empty for slash commands. |
| `args` | `[]const u8` | Raw, trimmed remainder after the command name. May be empty. For non-slash lines this is the original text. |
| `raw` | `[]const u8` | The original, unmodified input line. |

**Invariants**:
- A slash command yields a non-empty `command`.
- `args` is the substring after the first whitespace following the command,
  trimmed of surrounding whitespace.
- The parser performs no command-specific interpretation of `args`.

## Result

What a handler returns after handling an intent.

| Field | Type | Notes |
|-------|------|-------|
| `output` | `[]const u8` | Text the REPL prints back to the output sink. |
| `exit` | `bool` | When `true`, the REPL loop terminates after printing. |

## Handler

A unit that receives an `Intent` and produces a `Result`. Defined behind a
vtable interface so it can be injected and tested in isolation.

| Field | Type | Notes |
|-------|------|-------|
| `ctx` | `*anyopaque` | Pointer to the concrete handler's state. |
| `vtable` | `*const VTable` | `{ handle: fn (ctx, alloc, intent) anyerror!Result }` |

**Behavior**: `handle` consumes an `Intent`, performs (or delegates) the command
logic, and returns a `Result`. Any implementation is substitutable for any other
(LSP).

## Dispatcher

The routing component. Maps a command name to its registered handler and invokes
it. Depends only on the `Handler` interface.

| Field | Type | Notes |
|-------|------|-------|
| `handlers` | `std.StringArrayHashMap(Handler)` | command name → handler. |
| `default_handler` | `?Handler` | Optional handler for non-slash (`command = ""`) lines. |

**Behavior**:
- `register(command, handler)` — stores the mapping; rejects duplicate
  registration.
- `dispatch(alloc, intent) -> Result` — looks up `intent.command`:
  - registered → invoke that handler.
  - unknown command → return an "unknown command" `Result`, invoke no handler.
  - `command = ""` → invoke `default_handler` if set, else no-op `Result`.

**Invariant**: The dispatcher never contains command-specific branching. All
command behavior lives behind registered handlers (SC-005).

## Input / Output Source

The stream the REPL reads lines from and writes results to. Both are injected
(interchangeable) so tests use scripted input and captured output.

- **Input**: an injected line reader (e.g. `std.Io.Reader`) yielding one line at
  a time; end-of-input terminates the loop.
- **Output**: an injected sink the REPL writes each `Result.output` to.

## Relationships

```text
REPL ──reads──> InputSource
REPL ──writes─> OutputSink
REPL ──uses───> Dispatcher
Dispatcher 1──* Handlers (registered by command name)
Handler ──consumes──> Intent
Handler ──produces──> Result
Parser ──produces──> Intent (no side effects)
```

No persistent state; every entity is ephemeral per input line.
