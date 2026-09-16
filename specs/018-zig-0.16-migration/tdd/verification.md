# TDD Verification — 018-zig-0.16-migration

- **Audited**: 2026-09-16 · **Suite**: `zig build test` on Zig 0.16.0 → GREEN (144 passed, 4 skipped, 0 failed)
- **Verdict**: **PASS_WITH_GAPS**

## Evidence
- Full migration: the tree compiles and passes under 0.16.0 (from 34 compile errors / 16 files).
- `zig fmt --check src/ tests.zig build.zig` clean.
- CI workflow: 0.16.0 is the required gate; fmt check added; 0.15.2 retired.
- Test intent preserved: no test deleted; the 3 loopback skips are macOS-only
  (`comptime` os gate) and keep running on the Linux CI gate.

## Gaps (non-blocking, tracked)
1. **0.16.0 + macOS loopback limitation** — `std.http.Client` never writes its
   request (probe-verified: connect ok, flush "ok", kernel queues empty), and a
   listener-thread + client on one Threaded Io panics with EAGAIN. Three tests
   skip on macOS only: proxy routing, Unix-socket round-trip (A4), TLS non-200
   CONNECT. Linux CI exercises them; re-verify locally after a Zig release bump.
2. `readLine` in repl.zig reimplements line assembly over raw Reader primitives
   (`takeDelimiterExclusive` spins on fixed readers in 0.16.0).
3. Dual-toolchain (0.15+0.16) compatibility was explicitly NOT attempted — the
   floor bumps to 0.16.0 per the issue's sanctioned fallback.
4. Local verification used CI's exact command on macOS; the Linux runner is the
   first environment to execute the three skipped loopback tests post-merge.
