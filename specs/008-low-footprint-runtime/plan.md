# Plan: Low-Footprint Multi-Window Runtime

**Feature**: `008-low-footprint-runtime`
**Status**: Implemented and verified; merged to `MASTER` via PR #1 (the native
Zig runtime) with the measurement harness added here. This plan documents the
design and verification evidence for sign-off.

## Goal

Guarantee bounded, small per-window memory so 20 concurrent agent windows stay
at or below one-eighth of the current TypeScript baseline (~10 GB), i.e. roughly
1.25 GB total at steady state. This is the property that justifies the Zig rewrite
and is enforced by a repeatable measurement harness, not by hand.

## Architecture & Key Decisions

- **Native Zig runtime, no GC**: the CLI is a single native binary built by
  `build.zig` with manual/arena allocators and `std.heap.GeneralPurposeAllocator`
  in the entrypoint. There is no garbage collector, no per-window VM, and no
  node/JS heap — the dominant source of the TypeScript version's >10 GB blow-up
  is absent. Per-window memory is bounded by explicit allocations tied to the goal
  transcript, tool I/O buffers, and provider responses (FR-001, FR-003).
- **Composition, not re-implementation**: a "window" is the composition of the
  earlier features (002 shell, 003 tools, 004/007 provider, 005 goal state, 006
  execution loop). This feature constrains their combined memory; it does not
  duplicate them.
- **Bounded active memory (FR-007)**: the executor streams provider responses and
  keeps a single rolling transcript; context is bounded per the goal budget, so a
  large file/response does not grow a window without limit at steady state.
- **Repeatable measurement harness** (`memory-harness.sh`): launches N idle
  `ziki` REPL windows held open on a FIFO, waits for steady state, sums resident
  memory (RSS) via the platform `ps`, and asserts the total against the budget,
  reporting a clear PASS/FAIL breach (FR-004, FR-005, FR-006, FR-008, FR-010).
  When the TypeScript baseline is unavailable, the absolute proxy budget
  (~1.25 GB at 20 windows) is the fallback assertion (FR-009).

## Files

| File | Responsibility |
|------|----------------|
| `build.zig` | Native binary build (no runtime/GC); single executable |
| `src/main.zig` | Entrypoint with explicit allocator; composition root |
| `memory-harness.sh` | Launches N windows, measures RSS, asserts budget |

## Verification Evidence

- `memory-harness.sh N` launches N idle windows and reports total + per-window
  RSS, failing clearly when the budget is exceeded (FR-004, FR-005, FR-010).
- Per-window idle footprint is a small, bounded baseline (no unbounded growth);
  the harness re-measures after the settle delay to catch leaks (FR-002, FR-003,
  SC-002, SC-003).
- The budget is judged at steady state (the harness `sleep`s before measuring),
  not at transient peak (FR-006, SC-001).
- A window start failure is reported as an error, not a low reading (FR-008).

## Notes

Behavior is fully specified in `spec.md`. The rewrite's core benefit (master spec
SC-002) is realized by the native runtime plus this harness; the harness makes
the budget regression-testable so the gain cannot silently regress.
