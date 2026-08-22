# Quickstart & Validation: Zig Goal CLI (ziki)

Runnable scenarios proving spec 001 works end-to-end. Implementation details
belong in `tasks.md` / the implementation phase; this is the validation guide.

## Prerequisites

- Zig 0.15.2 installed (`zig version`).
- Build the binary: `zig build` (produces `./zig-out/bin/ziki`).
- Run the full suite: `zig build test`.

## Scenario A — Unit / TDD gates (per module)

```bash
zig build test
```

Expected: all `_test.zig` pass. This is the constitution's shippable gate
(Principle V): every behavior has a test written before its code.

## Scenario B — End-to-end goal completion (no network)

Integration test `agent/executor_test.zig` runs `GoalExecutor` with
`FakeProvider` + real `read`/`edit`/`bash` tools against a temp dir:

```bash
zig build test -- ziki-executor-e2e
```

Expected: the scripted goal (e.g. "create hello.txt containing 'hi'") reaches
`status == completed`, the file exists with the expected content, and the goal
state JSON records `completed`. This satisfies SC-001's mechanism (a goal is
driven to completion autonomously) without credentials.

## Scenario C — Real provider smoke (optional, needs key)

```bash
export ZIKI_PROVIDER=openai_custom
export ZIKI_ENDPOINT=https://api.openai.com/v1
export ZIKI_API_KEY=sk-...
zig build run -- /goal "create a file named done.txt with the text OK" --criterion "done.txt exists with OK"
```

Expected: the binary drives the goal to `completed`, prints `status: completed`
and a `summary:` block. Gated behind `ZIKI_API_KEY` so it is skipped in CI
without credentials.

## Scenario D — Clear errors (FR-010)

```bash
# no provider configured
zig build run -- /goal "do something"
# expected: error: no provider configured — set one via /provider or config

# malformed goal
zig build run -- /goal ""
# expected: error: goal objective must not be empty
```

## Scenario E — Resume after restart (FR-006, SC-004)

```bash
# start a goal, kill the process mid-way (Ctrl-C), then:
zig build run -- /status
# expected: shows the active goal with partial progress, not a fresh prompt
zig build run -- /goal "<same objective>"   # resumes, does not restart
```

## Scenario F — Memory budget (follow-up slice 008, SC-002)

Formal 20-window measurement lives in the 008 slice. Architecture designed for
it: per-turn arena reset, bounded history, no global caches. Verified
informally by running several windows and observing flat RSS via `ps`.

## Definition of Done check (spec)

Slash `/goal` accepts an objective (+ optional criterion), the agent completes
it autonomously to a stop condition, and the outcome matches Kimi's `/goal`
behavior for representative coding tasks (SC-001). Cosmetic/theming irrelevant
(spec). Scenario B is the automated proof; Scenario C is the real-world proof.
