# Tasks: [Lane B] Provider depth
**Branch**: `014-provider-depth` | **Spec**: `spec.md` | **Plan**: `plan.md`

- [x] **T1** *(behavior)* Per-provider request-shape + fixture tests (kilo, zai, kimi, openai_custom) via capturing transport. (US1)
- [x] **T2** *(behavior)* `FinishReason.unknown` + executor notes for `length` / tool-call cutoff / unknown. Update the `.stop`-pinned test. (US2)
- [x] **T3** *(behavior)* 401/403 → `Unauthorized`/`Forbidden`; fail-fast in the retry loop; executor `.blocked` with credential guidance; no key material in messages. (US3)
- [x] **T4** *(behavior)* 400/404 → `ModelNotFound` + models-list probe + `Provider.errorHint()`; executor blocked status includes the hint. (US4)
- [x] **T5** Full `zig build test` green (0.15.2); verification evidence recorded.
