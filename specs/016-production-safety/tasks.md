# Tasks: [Lane D] Production safety
**Branch**: `016-production-safety` | **Spec**: `spec.md` | **Plan**: `plan.md`

- [x] **T1** *(behavior)* Push gate: compound/-C/wrapper/alias bypass shapes gated; safe shapes stay allowed. (US1, FR-001)
- [x] **T2** *(behavior)* Already-applied pre-check: short-circuit completed after exactly one provider call; resume unaffected. (US2, FR-002)
- [x] **T3** *(behavior)* Report completeness: exact-report integration test (intentional untracked + reverted drift + surviving pre-existing file). (US3)
- [x] **T4** Full `zig build test` green (0.15.2); verification evidence recorded.
