# Bug Assessment: [Lane E] Herdr/skills e2e + spec 012 + two confirmed bugs (use-after-free, SESSION_ID)

- **Slug**: lane-e-herdr-skills-e2e
- **Created**: 2026-09-15T20:03:54Z
- **Source**: https://github.com/arrrrny/ziki/issues/20
- **Verdict**: valid — two bugs pre-confirmed by the reporter with exact code paths; plus scoped feature work
- **Severity**: unknown (labeled `bug`, `enhancement`, `night-lane`)

## Report (verbatim or summarized)

Night-lane issue with two confirmed bugs (fix first, small) plus two feature items, all
part of the night parallelization plan. Audit baseline: spec 009-skill strict 55%, spec
011 strict 62.5%. Full body recorded in [issue.md](issue.md).

## Symptom

1. **Herdr use-after-free**: `buildStatePublisher` (`src/main.zig:113-115`) frees
   `api_url` immediately after `HerdrHttpClient.init` stored it by reference
   (`src/agent/herdr.zig:16` performs no dupe). Any real reporter use reads freed memory.
2. **`SESSION_ID` hard-coded to `"default"`** (`src/main.zig:35`, used at `:241` and
   `:251`): multiple Ziki instances running side by side share one session, breaking
   per-window goal isolation — the core swarm use case.

## Reproduction

1. Run any code path that makes the herdr state publisher actually use the stored
   `base_url` after setup (e.g. a real reporter call) under `std.testing.allocator` →
   use-after-free / allocator error. A test holding the client past the `init` caller's
   free reproduces it deterministically.
2. Launch two Ziki instances in the same repository → both persist goals under session
   id `"default"` → state collisions.

## Suspected Code Paths

- `src/agent/herdr.zig` — `HerdrHttpClient.init` (no dupe of `base_url`), deinit.
- `src/main.zig` — `buildStatePublisher` (:113-115, frees `api_url` too early), `SESSION_ID`
  constant (:35) and its uses (:241, :251).
- `src/agent/state_sync_test.zig` — existing herdr/state-sync tests to extend.
- `src/transport/` — Transport interface where the spec 012 socket transport plugs in
  (new `src/transport/socket`).

## Root Cause Hypothesis

1. `HerdrHttpClient` stores a borrowed slice of caller-owned memory without duplicating
   it; the caller's lifetime ends before the client's.
2. Session identity was never parameterized — a compile-time constant stands in for a
   per-instance value.

## Proposed Remediation

1. Dupe `base_url` in `HerdrHttpClient.init` (own the memory), free it in `deinit`, and
   add a regression test that survives `std.testing.allocator`.
2. Derive `SESSION_ID` from the environment / window id, defaulting sensibly when unset;
   add a test proving repository isolation (different ids → different state).

Feature work in the same lane (delivered on the same branch per the issue):

3. Skill-driven end-to-end goal test (spec 009): load a skill from disk → appears in the
   system prompt listing → executor fetches it via the `skill` tool → artifact written.
   Full loop with `FakeProvider` + `FakeFs` + `tmpDir`.
4. Spec 012 local-socket transport: review `origin/012-socket-connection` (never merged),
   port onto current master, add socket transport tests behind the existing Transport
   interface.

## Risks & Considerations

- `src/main.zig` overlaps Lanes A/C; the two bug fixes are tiny and land first.
- Regression tests must pass under `std.testing.allocator` to prove the lifetime fix.
- Suggested branch: `017-herdr-skills-e2e`.

## Open Questions

- None blocking — the reporter pre-confirmed both bugs with exact locations and fixes.
