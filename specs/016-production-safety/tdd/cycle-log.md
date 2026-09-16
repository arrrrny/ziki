# TDD Cycle Log — 016-production-safety

## Baseline
- **Commit**: master @ bb7d6c2 · **Branch**: `016-production-safety`
- **Suite**: GREEN (145 passed, 1 gated skip) · **Behaviors**: 3 acceptance, all PENDING

## Cycle 1 — A1/A2/A3

- **RED**: gate test — `BYPASS not caught: cd repo && git push origin main` (and the
  wrapper/alias shapes) against the naive tokenizer; A2 — no short-circuit (2 model
  calls, normal completion, no "already done"); A3 — report assertions.
- **GREEN**: recursive intent resolver (quote-aware compound split, `-c`-wrapper
  recursion, git global-option skipping, unknown-subcommand fail-closed, `--dry-run`
  safe) + the already-applied pre-check (fresh goals only, `(try verify(...)) orelse
  false` for the 013 optional-bool verify). Two test fixes during the cycle: the A3
  script initially assumed a pre-check for a criterion-less goal (none runs), and the
  drift `run_command` had to target the tmp repo by absolute path (BashTool spawns in
  the process cwd). Suite: 149 passed, 1 gated skip → green.

## Mutation checks

| # | Mutant | Result |
|---|--------|--------|
| M1 | Gate reduced to the naive per-segment `git` check (no compound/wrapper resolution) | **KILLED** — A1 reports uncaught bypass shapes |

Reverted exactly; final suite green (149 passed, 1 gated skip, no leaks).
