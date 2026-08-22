# Quickstart & Validation: CLI Shell Dispatcher

**Feature**: 002-cli-shell-dispatcher

## Prerequisites

- Zig 0.15.2
- This repository cloned

## Run the test suite (primary validation)

```bash
zig build test
```

All dispatcher/parser/REPL tests must be green. These tests feed raw input lines
and assert the resulting intents and dispatch calls — no live agent, provider,
or filesystem is touched.

## What the tests prove (maps to Success Criteria)

- **SC-001** — Representative lines for `goal`, `stop`, `provider`, `goals`,
  `help` parse into the correct command + args.
- **SC-002** — Dispatching an intent invokes **only** the registered handler for
  that command; no unrelated handler runs.
- **SC-003** — A scripted sequence of ≥10 lines is processed in order and
  produces the expected ordered intents + outputs with no human at the keyboard.
- **SC-004** — Malformed input, unknown commands, and missing arguments each
  yield a clear message with no crash.
- **SC-005** — The dispatcher is exercised with every handler swapped for a fake;
  behavior is unchanged, proving zero command-specific logic in the dispatcher.

## Manual REPL check

```bash
zig build
./zig-out/bin/ziki
ziki> /help
ziki> /provider kimi
ziki> /stop
```

- Each line is parsed and routed; output is printed; the prompt returns.
- `/stop` (or end-of-input / Ctrl-D) terminates the loop cleanly.
- An unknown command prints a clear "unknown command" message and does not crash.
- An empty line is ignored.

## Scripted input (pipelines / CI)

Pipe lines into the binary; the engine consumes them in order and exits on
end-of-input:

```bash
printf '/help\n/provider kimi\n/stop\n' | ./zig-out/bin/ziki
```

Expected: the three intents dispatched in order, then the loop ends.
