# Tasks: Provider Integrations (opencode, kilo, z.ai, kimi)

**Input**: Design documents from `/specs/007-provider-integrations-four/`
**Prerequisites**: `spec.md`, `plan.md`

**Tests**: Required — the constitution (TDD, Principle V) mandates tests FIRST.
The implementation was built test-first; the provider registry ships with an
independent test, and interchangeability is proven by the executor tests.

**Organization**: Tasks grouped by user story (US1–US5 from spec.md).

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)

## Phase 1: Setup (Shared Client)

- [X] T001 Implement the `OpenAIProvider` client in `src/provider/openai.zig`
  (from spec 004) so the four named providers can be config-driven instances of
  one client (OCP, FR-001, FR-009).

---

## Phase 2: User Story 1–4 — Each named provider is a usable backend (P1)

- [X] T002 [P] [US1] Register the `opencode` preset (endpoint/model) and verify
  it builds a `Provider` and drives a scripted goal to `completed` (FR-003,
  FR-005).
- [X] T003 [P] [US2] Register the `kilo` preset and verify the same (FR-003,
  FR-005).
- [X] T004 [P] [US3] Register the `z.ai` preset and verify the same (FR-003,
  FR-005).
- [X] T005 [P] [US4] Register the `kimi` preset and verify the same; also the
  `cliproxy` (mimo-v2.5) preset added per user request (FR-003, FR-005).

## Phase 3: User Story 5 — Switch providers without agent changes (P2)

- [X] T006 [P] [US5] Implement `presets.zig` (`PRESETS` table, `findPreset`,
  `build`) so the active provider is selected by name at setup with no agent/loop
  change; a live `cliproxy` goal confirmed end-to-end (FR-007, FR-008, SC-003).

---

## Phase 4: Polish & Cross-Cutting

- [X] T007 Implement `error.UnknownProvider` for unregistered names and clear
  missing-config errors before any request (FR-006, FR-010, SC-004).
- [X] T008 Verify `zig build test` — presets test + executor swap-in tests pass;
  FR-001..FR-010 and SC-001..SC-005 satisfied; all six backends interchangeable.

## Dependencies & Execution Order

- T001 (shared client) is the prerequisite for all presets.
- US1–US4 (T002–T005) are independent preset registrations → parallel.
- US5 (T006) depends on the presets table existing.
- T007 (errors) + T008 (verification gate) last.

## Notes

- One client, N presets: adding a backend is data (a `Preset` row), not new
  branching — Open/Closed satisfied.
- The master spec's five-provider requirement (FR-004, SC-003) is closed across
  the six registered backends (the four named + openai_custom + cliproxy).
