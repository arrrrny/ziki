# Contract: CLI Command Schema

**Feature**: 002-cli-shell-dispatcher
**Scope**: The dispatcher parses and routes these commands. The *behavior* of
each command is owned by its registered handler (defined in later specs); this
contract defines only the **intent shape** each input line produces.

## Slash commands (initial set)

| Input line | `Intent.command` | `Intent.args` | Notes |
|------------|-----------------|--------------|-------|
| `/goal add a parser to the project` | `goal` | `add a parser to the project` | Flags (`--criterion`, `--provider`) are part of `args`; parsed by the handler, not the dispatcher. |
| `/stop` | `stop` | `""` (empty) | |
| `/provider openai` | `provider` | `openai` | |
| `/goals` | `goals` | `""` (empty) | Lists goals. |
| `/help` | `help` | `""` (empty) | |

## Non-slash input

| Input line | `Intent.command` | `Intent.args` | Routing |
|------------|-----------------|--------------|---------|
| `just some text` (no leading `/`) | `""` (empty) | `just some text` | Routed to `default_handler` if registered, else no-op. Never mis-parsed as a command. |

## Edge-case contract

| Input | Outcome |
|-------|---------|
| Empty or whitespace-only line | No intent, no dispatch (no-op). |
| `/` with no name, or invalid characters | Parsing error; REPL prints a clear message, loop continues. No handler invoked. |
| Valid command with no handler registered | Dispatcher returns an "unknown command" `Result`; no handler invoked. |
| Duplicate `register` of the same command | Registration rejected (error) at setup time. |
| `/help` with trailing args | `command = help`, `args = <trailing>` (handler decides relevance). |

## Dispatch guarantee (SC-005)

The dispatcher performs a key lookup only. It never inspects `command` to decide
behavior; the registered handler for that key does the work. Swapping every
handler (e.g. all fakes in a test) requires zero changes to the dispatcher.
