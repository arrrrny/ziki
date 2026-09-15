# Bug Issue: [Lane E] Herdr/skills e2e + spec 012 + two confirmed bugs (use-after-free, SESSION_ID)

- **Slug**: lane-e-herdr-skills-e2e
- **Fetched**: 2026-09-15T20:03:54Z
- **Issue**: 20
- **URL**: https://github.com/arrrrny/ziki/issues/20
- **State**: open
- **Severity**: unknown
- **Author**: arrrrny
- **Labels**: bug, enhancement, night-lane

## Body

Part of the night parallelization plan (tracker: see the "Night lanes" tracking issue). Audit: spec 009-skill strict 55%, spec 011 strict 62.5% (best-shaped specs) — plus two confirmed bugs found while unblocking the suite.

## Bugs (fix first, small)

- [ ] **Herdr use-after-free** — `buildStatePublisher` (`src/main.zig:113-115`) frees `api_url` right after `HerdrHttpClient.init` stored it **by reference** (`src/agent/herdr.zig:16` does no dupe). Any real reporter use reads freed memory. Fix: dupe `base_url` in `HerdrHttpClient.init` (and free in deinit), add a test that survives `std.testing.allocator`.
- [ ] **`SESSION_ID` hard-coded to `"default"`** — `src/main.zig:35`, used at `:241` and `:251`; breaks per-window goal isolation when multiple Ziki instances run side by side (which is the whole swarm point). Derive from env/window id, default sensibly, and test repository isolation.

## Feature work

- [ ] **Skill-driven end-to-end goal test** — load a skill from disk → verify it appears in the system prompt listing → executor fetches it via the `skill` tool → artifact written. Full loop with `FakeProvider` + `FakeFs` + `tmpDir`. (spec 009-skill-system)
- [ ] **Spec 012 local-socket transport** — draft exists on `origin/012-socket-connection` (never merged). Review the branch, port onto current master, add socket transport tests behind the existing Transport interface.

## Touches

`src/agent/herdr.zig`, `src/main.zig`, `src/agent/state_sync_test.zig`, new `src/transport/socket` if 012 proceeds — **`src/main.zig` overlaps Lanes A/C; the two bug fixes are tiny, land them first.**

## Acceptance

- `zig build test` green; bug fixes each carry a regression test
- Suggested branch: `017-herdr-skills-e2e`

## Comments

None.
