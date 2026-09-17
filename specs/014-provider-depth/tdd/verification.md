# TDD Verification — 014-provider-depth

- **Audited**: 2026-09-15 · **Suite**: `zig build test` (0.15.2) → GREEN (151 passed, 1 gated skip, no leaks)
- **Verdict**: **PASS_WITH_GAPS** (no blocking findings)

## Evidence
- 4 acceptance + 1 unit behaviors DONE with red→green evidence ([cycle-log.md](cycle-log.md)).
- Mutant M1 (401 → generic ProviderError) killed.
- Credential/model rejections are fail-fast (1 wire call asserted), blocked status carries actionable text; no key material in any message (static strings only).
- Models probe: GET `{endpoint}/models` asserted on the wire; hint surfaced through `Provider.errorHint()` into the goal progress.

## Gaps (non-blocking)
1. A1 passed on arrival (pinning/characterization behavior over the existing request builder) — no red; compensated by fixture parsing catching real deltas.
2. Fixtures cover one success shape per backend + one tool_calls shape (kimi); error-body shapes beyond status codes are not parsed (by design — messages never embedded).
3. `models_hint` intentionally outlives the error (provider-stored, bounded, replaced per probe; freed by the owner — never by the provider itself).
4. finish_reason notes record in the job report; the loop does not retry truncated turns (deterministic single-surface behavior).
