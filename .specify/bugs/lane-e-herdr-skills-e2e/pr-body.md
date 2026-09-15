## Summary

Delivers all four items from the Lane E issue in one cycle, run through the full
bug-whole (fix → test → PR) workflow with the TDD red-green loop:

**Bug fixes (each carries a regression test)**

1. **Herdr use-after-free** — `HerdrHttpClient` stored `base_url` by reference while
   `buildStatePublisher` freed `api_url` immediately after `init`, so any real reporter
   use read freed memory. `init` now dupes the URL and a new `deinit` frees it; the
   run scope cleans up the client slot. Regression test: caller frees its copy, client
   still reports correctly under `std.testing.allocator`.
2. **`SESSION_ID` hard-coded to `"default"`** — replaced with `resolveSessionId`
   (`ZIKI_SESSION_ID`, else `HERDR_PANE_ID`, else `"default"`; empty = unset), threaded
   through `/goal`, `/stop`, `/status`, `/goals`; the stop-file path is built at
   runtime. Side-by-side windows no longer share goal state — repository isolation is
   asserted per session (`goal.pane-1.json` vs `goal.pane-2.json`).

**Feature work**

3. **Skill-driven e2e goal test (spec 009)** — loads a skill from a real tmpDir via
   `RealFs`, asserts it appears in the system-prompt listing, fetches it through the
   `skill` tool inside a scripted `GoalExecutor.run`, and verifies the artifact is
   written (FakeProvider-style scripting + FakeFs).
4. **Spec 012 local-socket transport** — ported the spec draft from the never-merged
   `origin/012-socket-connection` and implemented `SocketTransport` behind the existing
   `Transport` interface: `unix://` URLs select it at the composition root, `http(s)`
   keeps the HTTP transport untouched (FR-004), other schemes fail fast with a clear
   message (FR-007). HTTP-shaped wire format over the socket, close-delimited response
   parsing, connection errors stay best-effort for the goal loop (FR-006). Zero new
   dependencies (FR-005).

## Changes

| File | Change |
|------|--------|
| `src/agent/herdr.zig` | Bug 1: owning `init`/`deinit` + UAF regression test |
| `src/main.zig` | Bug 2: session-id resolution + threading; spec 012 transport selection; 2 new tests |
| `src/provider/transport_socket.zig` | New: socket transport + 5 tests (selection, URL split, live-socket round-trip, failure path, response parse) |
| `src/skill/e2e_test.zig` | New: skill-driven e2e goal test |
| `tests.zig` | Aggregator imports the two new modules |
| `specs/012-socket-connection/` | Spec draft ported from `origin/012-socket-connection` |
| `.specify/bugs/lane-e-herdr-skills-e2e/` | Bug cycle records (assessment, fix, test, TDD artifacts) |

## Local Verification

- `zig build test` (Zig 0.15.2, the CI gate toolchain): **green** — 123 passed,
  1 skipped (network-gated live-provider test that skips without `ZIKI_API_KEY`).
- Mutation checks (no Zig mutation tool installed → deliberate mutants): ownership
  removal, session pinned to `"default"`, skill tool returning an empty body — **all
  three killed** by the new tests, then reverted exactly.
- TDD audit verdict: `PASS_WITH_GAPS` (non-blocking gaps recorded) —
  `.specify/bugs/lane-e-herdr-skills-e2e/tdd/verification.md`.

Assessment: `.specify/bugs/lane-e-herdr-skills-e2e/assessment.md`

Closes #20.
