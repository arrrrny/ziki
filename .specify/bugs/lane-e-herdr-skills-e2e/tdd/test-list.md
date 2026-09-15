# Test List — lane-e-herdr-skills-e2e

Derived from `spec.md` (synthesized from issue #20). Profile: `.specify/memory/tdd-profile.md`
(zig / `zig build test` full suite per check; single/file runners unavailable).

## Outer acceptance behaviors

| ID | Behavior (test name) | Trace | Status |
|----|----------------------|-------|--------|
| A1 | `HerdrHttpClient outlives the caller's api_url (use-after-free regression)` — caller frees URL, client still reports correctly under `std.testing.allocator` | spec Bug 1 / AS-1, AS-2 | DONE |
| A2 | `resolved session ids isolate goal repositories` — precedence-derived ids keep two repos in one state dir isolated | spec Bug 2 / AS-4 | DONE |
| A3 | `skill-driven goal e2e: disk skill → system prompt listing → skill tool fetch → artifact written` — tmpDir+RealFs skill root, FakeProvider, FakeFs, full GoalExecutor.run | spec Feature 1 / AS-1..3 | DONE |
| A4 | `SocketTransport round-trips an HTTP-shaped request over a Unix socket` — real listener thread, wire shape + response parse | spec Feature 2 / AS-2 | DONE |

## Inner unit behaviors

| ID | Behavior (test name) | Trace | Status |
|----|----------------------|-------|--------|
| U1 | `resolveSessionIdFrom precedence: ZIKI_SESSION_ID > HERDR_PANE_ID > "default"` (empty = unset boundary) | spec Bug 2 / AS-1..3 | DONE |
| U2 | `socket URL selection: unix → socket, http(s) → http, else unsupported` | spec Feature 2 / AS-1 | DONE |
| U3 | `unix URL splits into socket path and request path` | spec Feature 2 / FR-003 | DONE |
| U4 | `SocketTransport propagates a missing-socket-path error` (clear failure, reporter swallows) | spec Feature 2 / AS-3 | DONE |

## Notes

- Zig has no per-test runner (`single: null`); every red/green check runs `zig build test`.
- A compile-failing test is a valid red for not-yet-existing APIs (Zig collects tests at compile time).
- Mutation tooling absent; audit uses deliberate mutants (profile `mutation: null`).
