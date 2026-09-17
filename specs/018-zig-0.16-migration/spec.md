# Feature Specification: Zig 0.16 std.Io migration

**Feature Branch**: `018-zig-0.16-migration` | **Issue**: [#21](https://github.com/arrrrny/ziki/issues/21) (Lane F) | **Created**: 2026-09-15

**Input**: Issue #21 — the tree does not compile on Zig 0.16.0 (31+ compile errors across 18 files).

## User Scenarios & Testing *(mandatory)*

### US1 — The suite builds and passes on 0.16.0 (P1)
**AS-1**: `zig build test` under Zig 0.16.0 compiles the whole tree and passes the suite (the network-gated live test may skip). **AS-2**: behavior is preserved — every existing test keeps its intent (the 0.15-era APIs are replaced, not the semantics).

### US2 — CI reflects the new floor (P2)
**AS-1**: The 0.16.0 CI job becomes required (`allow_fail: false`); the 0.15.2 job is retired. **AS-2**: a `zig fmt --check` gate is added.

### US3 — Formatting + documentation (P3)
**AS-1**: `zig fmt` passes over `src/`, `tests.zig`, `build.zig`. **AS-2**: `.specify/memory/tdd-profile.md` and README toolchain notes describe 0.16.x.

## Requirements
- **FR-001**: All I/O goes through the 0.16 `Io` capability model: fs (`std.Io.Dir`), env (Environ.Map via `src/compat.zig`), child processes, net, and the clock (`io.now(.real)` replacing `std.time.nanoTimestamp`).
- **FR-002**: The project DI interfaces (`Fs`, `Provider`, `Tool`, `Transport`, `StatePublisher.Sink`) keep their shapes; only implementation internals adapt. `src/compat.zig` is the single owner of the Io/environ state (main initializes it; tests use `std.testing.io`).
- **FR-003**: The project floor bumps to 0.16.0 (dual-toolchain compatibility explicitly NOT attempted, per the issue's fallback).
- **FR-004**: No third-party dependencies; no behavior changes beyond what the API migration requires.

## Success Criteria
- SC-001: `zig 0.16.0 build test` green locally and (after merge) in CI as the required check.
- SC-002: `zig fmt --check` clean.
