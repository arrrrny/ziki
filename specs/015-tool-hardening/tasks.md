# Tasks: [Lane C] Tool hardening

**Branch**: `015-tool-hardening` | **Spec**: `spec.md` | **Plan**: `plan.md`

## Phase 1 — Confinement (US1)

- [x] **T1** *(behavior)* `confine.zig`: lexical `..`-escape + absolute-outside-root + tilde refusals; FakeFs tests. (FR-001, AS-1/2)
- [x] **T2** *(behavior)* `Fs.realpath` + symlink-escape refusal: RealFs tmpDir symlink → structured refusal, fail closed. (FR-001, AS-3)
- [x] **T3** Wire `confine.check` into read/edit/write/search tools; refusal result shape `confined: …`. (FR-001)

## Phase 2 — Structured errors (US2)

- [x] **T4** *(behavior)* Executor: failed tool call / unknown tool → tool message `error: <message>`, model can react. (FR-002, AS-1)

## Phase 3 — Edit modes (US3)

- [x] **T5** *(behavior)* `edit_file` mode=create (create-if-missing, refuse existing), mode=delete (remove, refuse missing); FakeFs tests. (FR-003, AS-1..3)

## Phase 4 — Directory search (US4)

- [x] **T6** *(behavior)* `search_file` dir= recursive walk + max_files bound (default 256); FakeFs tree test. (FR-004, AS-1/2)

## Phase 5 — Verify

- [x] **T7** Full `zig build test` green on 0.15.2; no pre-existing test regressed; verification evidence recorded. (SC-001/002)
