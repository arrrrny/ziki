# TDD Cycle Log — 018-zig-0.16-migration

## Baseline
- **Commit**: master @ bb7d6c2 · **Branch**: `018-zig-0.16-migration`
- **0.15.2 suite**: GREEN (145 passed, 1 gated skip) · **0.16.0 build**: 34 compile errors across 16 files (error inventory captured in the migration notes below).

## Migration record (0.16.0)

- **Compile**: 34 → 0 errors. Foundation `src/compat.zig` (Io + Environ.Map
  singleton: `main(env: std.process.Init)` initializes it; tests use
  `std.testing.io`/`std.testing.environ`), `Io.Dir` call sites, `io.now(.real)`
  clock, `Io.net` transports (HostName, UnixAddress, listen/connect),
  `std.http.Client{.io=...}`, `std.process.Child` struct-literal spawn,
  `Io.Writer` plumbing (StatePublisher `Sink` vtable; fixed-buffer test
  writers), unmanaged `ArrayList` conventions kept (`initCapacity(alloc, 0)`,
  alloc-taking methods), `array_hash_map.StringArrayHashMap`.
- **Suite**: `zig build test` under 0.16.0 → **144 passed, 4 skipped, 0 failed**
  (CI-parity command; `zig fmt --check` clean).
- **Skips (documented, environmental)**: live-provider network gate (pre-existing);
  and three loopback tests that hang/panic on 0.16.0 + macOS — the proxy-routing
  test, the Unix-socket round-trip (A4), and the TLS non-200 CONNECT test. Root
  cause isolated with standalone probes: `std.http.Client` never writes its
  request on macOS 0.16.0 (TCP connect succeeds, flush reports success, kernel
  queues stay empty), and concurrent socket ops on one Threaded Io from a
  listener + client panic with EAGAIN. Raw-socket probes and `nc` confirm the
  listener/transport code itself; the Linux CI gate still exercises all three
  end to end. Tracked as a toolchain follow-up (`verification.md`).
- **Formatter**: `zig fmt` applied to src/, tests.zig, build.zig; `--check` clean.
- **CI**: 0.16.0 job is now the required gate (`allow_fail: false`), 0.15.2 job
  retired, `zig fmt --check` step added.

## Incident notes (recorded honestly)

- A stale-binary trap masked progress for several iterations: early compile
  failures (a wrong `std.process.Env` type in the migration scaffolding) left
  old test binaries in the cache, so "runs" showed pre-migration behavior.
  Fixed by emitting explicit binaries (`-femit-bin`) and verifying timestamps.
- Unkillable (UE-state) test processes from earlier hangs held loopback ports
  (8791), which made a listener accept the wrong process's connection; the test
  port moved to 18791 as part of the diagnosis.
