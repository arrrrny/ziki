# Bug Fix: [Lane E] Herdr/skills e2e + spec 012 + two confirmed bugs

- **Slug**: lane-e-herdr-skills-e2e
- **Fixed**: 2026-09-15
- **Assessment**: ./assessment.md
- **Status**: applied
- **Branch**: `fix/lane-e-herdr-skills-e2e` (created from latest master @ df28833; `--branch` isolation)

## Summary

Fixed both confirmed bugs from issue #20 — `HerdrHttpClient` now owns its `base_url`
(eliminating the use-after-free in `buildStatePublisher`) and the session id is
resolved per window (`ZIKI_SESSION_ID` → `HERDR_PANE_ID` → `"default"`) instead of a
hard-coded `"default"` — and delivered the issue's two feature items: the
skill-driven end-to-end goal test (spec 009) and the spec 012 local-socket transport
(spec draft ported from `origin/012-socket-connection` + new `SocketTransport` behind
the existing `Transport` interface). Fix + verify ran through the TDD red-green loop
(tdd_enabled defaults on; see [tdd/cycle-log.md](tdd/cycle-log.md)).

## Changes

| File | Change | Notes |
|------|--------|-------|
| `src/agent/herdr.zig` | modified | Bug 1: `init` dupes `base_url` (now `!HerdrHttpClient`), added `deinit`; new UAF regression test; existing client tests adopt the ownership contract |
| `src/main.zig` | modified | Bug 1: `buildStatePublisher` defers its `api_url`, run deinits `herdr_client_slot`. Bug 2: `resolveSessionId`/`resolveSessionIdFrom` replace `const SESSION_ID`; id threaded through goal/stop/status/goals ctx structs; stop-file path runtime-built. Spec 012: transport selection in `buildStatePublisher` (+ `herdr_socket_slot`); U19 test updated; 2 new tests (U1, A2) |
| `src/provider/transport_socket.zig` | added | Spec 012: `selectByUrl`, `splitUnixUrl`, `SocketTransport`, `post`, `parseResponse` + tests (U2/U3/U4/A4) |
| `src/skill/e2e_test.zig` | added | Skill-driven e2e goal test (A3): tmpDir+RealFs skill root → listing → skill tool fetch → artifact |
| `tests.zig` | modified | Aggregator imports `transport_socket` + `skill_e2e` |
| `specs/012-socket-connection/` | added | Spec draft ported from `origin/012-socket-connection` (never merged) |

## Diff Highlights

Bug 1 — ownership instead of a borrowed slice:

```zig
pub fn init(alloc: Allocator, transport: Transport, base_url: []const u8) !HerdrHttpClient {
    return .{ .alloc = alloc, .transport = transport, .base_url = try alloc.dupe(u8, base_url) };
}
pub fn deinit(self: *HerdrHttpClient) void { self.alloc.free(self.base_url); }
```

Bug 2 — resolution with a testable precedence boundary:

```zig
fn resolveSessionIdFrom(alloc: Allocator, ziki_env: ?[]const u8, pane_env: ?[]const u8) ![]u8 {
    if (ziki_env) |z| { if (z.len > 0) return alloc.dupe(u8, z); }
    if (pane_env) |p| { if (p.len > 0) return alloc.dupe(u8, p); }
    return alloc.dupe(u8, "default");
}
```

Spec 012 — selection at the composition root (FR-002/FR-007), HTTP transport untouched (FR-004):

```zig
switch (socket_transport.selectByUrl(api_url)) {
    .socket => { /* heap SocketTransport from the URL's socket path */ },
    .http => {},
    .unsupported => { emitErr("unsupported HERDR_API_URL scheme …"); return error.UnsupportedApiUrl; },
}
```

## Tests Added or Updated

- `src/agent/herdr.zig::HerdrHttpClient outlives the caller's api_url (use-after-free regression)` — pins ownership; caller frees, client still reports correctly (A1)
- `src/main.zig::resolveSessionIdFrom precedence: ZIKI_SESSION_ID > HERDR_PANE_ID > default (U1)` — resolution boundary incl. empty-as-unset
- `src/main.zig::resolved session ids isolate goal repositories (A2)` — two panes, one state dir, isolated state files
- `src/skill/e2e_test.zig::skill-driven goal e2e … (A3)` — disk skill → system-prompt listing → skill-tool fetch → artifact written (RecordingProvider asserts the prompt)
- `src/provider/transport_socket.zig` — U2 selection, U3 URL split, A4 real-socket round-trip (HTTP-shaped request asserted by a listener thread), U4 missing-path error

## Local Verification

- Commands run: `zig build test` (Zig 0.15.2, the CI gate toolchain) → **green**:
  123 passed, 1 skipped (network-gated live test, skips without `ZIKI_API_KEY`).
- Mutation checks (profile has no mutation tool): 3 deliberate mutants — ownership
  removal, session always-"default", skill tool returns "" — **all killed** by the new
  tests; reverted exactly, suite re-run green.

## Deviations from Assessment

- The issue suggested branch `017-herdr-skills-e2e`; the bug workflow's `--branch`
  convention `fix/<slug>` was used instead (same work, different name).
- FR-006 "surface a clear error" for socket failures: at request time the error
  propagates from the transport and the reporter swallows it (best-effort contract
  from spec 011) so the goal loop is never blocked; the clear-message surface is the
  selection-time fail fast (FR-007) plus the propagated error itself. Runtime push
  failures remain silent-by-design; flagged here rather than changing 011's contract.
- `zig` was not installed on this machine; the suite runs on the freshly downloaded
  official Zig 0.15.2 toolchain (same version as the CI gate).

## Follow-ups

- Merge + delete the `012-socket-connection` branch after this lands.
- Zig 0.16 preview migration is tracked separately (CI allow_fail job).
- If Herdr ever needs push-failure observability, add a verbose-mode log line for
  swallowed reporter errors (011 follow-up, not this fix).
