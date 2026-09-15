# TDD Cycle Log — 015-tool-hardening

## Baseline

- **Commit**: master @ bb7d6c2 (PR #24 merged; Lane E #23 merged)
- **Branch**: `015-tool-hardening`
- **Suite**: `zig build test` → GREEN (145 passed, 1 gated skip)
- **Behaviors**: 5 acceptance + 2 unit, all PENDING

## Cycle 1 — A1/A2/U1/U2 confinement

- **RED**: `confine.zig` with a permissive `check` stub + refusal tests + `Fs.realpath`
  vtable addition (RealFs realpath / FakeFs lexical join). Suite: A1 + A2 failed
  (`ExpectedRefusal` — stub refuses nothing); U1 passed (guard).
- **GREEN**: real `check` (lexical `..`, absolute-under-root component prefix,
  tilde refusal, realpath symlink detection incl. parent check) + wired into
  read/edit/write/search. One fix during the cycle: `underRoot` skipped empty
  components only on the root side (10 failures incl. pre-existing tool tests —
  `/wd/f.txt` judged outside `/wd`); component-skip on both sides → green 148 passed.

## Cycle 2 — A3/A4/A5

- **RED**: executor error-propagation test (CapturingProvider), edit create/delete
  tests, search dir/bound tests. Suite: all 4 failed for the right reasons
  (assertion: error text discarded; `UnknownField` for `mode`/`dir`).
- **GREEN**: dispatch appends `error: <message>` for failed tools; `edit_file`
  gains `mode` (create-if-missing/refuse-existing, delete/refuse-missing);
  `search_file` gains recursive `dir` + `max_files` (default 256, limit notice).
  Suite: 152 passed, 1 gated skip → green.

## Test-harness incident (recorded honestly)

The first cycle-2 red run deadlocked: the original A3 test retained
`req.messages` (a slice into the executor's run arena) past `run()` and read it
after the arena was freed → segfault; Zig 0.15's test runner then hung inside its
segfault handler (`handleSegfaultPosix` → `Progress.global_progress`). Fixed the
test to inspect messages during the provider call only (record a bool). No
production code was involved.

## Mutation checks

| # | Mutant | Result |
|---|--------|--------|
| M1 | `confine.check` returns null unconditionally | **KILLED** — A1 + A2 fail (2 failures) |

Reverted exactly; final suite green (152 passed, 1 gated skip).
