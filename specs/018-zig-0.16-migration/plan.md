# Implementation Plan: [Lane F] Zig 0.16 std.Io migration
**Branch**: `018-zig-0.16-migration` | **Spec**: `spec.md` | **Issue**: #21

## Summary
Bump the project floor to Zig 0.16.0: thread the `Io` capability through the platform boundary (a new `src/compat.zig` singleton owning `Io` + `Environ.Map`), migrate fs/net/process/time/env call sites, replace `AnyWriter`/`fixedBufferStream` writer plumbing with `std.Io.Writer`, flip CI to the 0.16 gate, and format the tree.

## Technical Decisions
- **D1 — compat singleton**: `src/compat.zig` owns the `Io` instance and the environ map. `main(env)` initializes it; tests reach `std.testing.io`/`std.testing.environ` lazily. This keeps the `Fs`/`Transport`/tool interfaces unchanged — only implementations touch Io.
- **D2 — env access**: all reads are comptime-known names routed through `compat.getenv`/`getEnvOwned` (mirror of the removed `getEnvVarOwned`).
- **D3 — writers**: `StatePublisher` takes a `Sink` vtable (matches the codebase's DI idiom, keeps state.zig Io-free); fixed-buffer test writers use `std.Io.Writer.fixed` + `buffered()`.
- **D4 — CI**: 0.16.0 becomes the only/required job; `zig fmt --check` added; 0.15.2 job retired (sanctioned fallback from the issue).
