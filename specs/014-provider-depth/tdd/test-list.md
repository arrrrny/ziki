# Test List — 014-provider-depth
Profile: zig, full `zig build test` per check.

| ID | Behavior (test name) | Trace | Status |
|----|----------------------|-------|--------|
| A1 | `per-provider request shape and fixture parsing (T1)` | US1, FR-001 | DONE |
| A2 | `finish_reason length/unknown/tool-cutoff are surfaced, not silent stops (T2)` | US2, FR-002 | DONE |
| A3 | `401/403 map to credential errors, fail fast, blocked status without key material (T3)` | US3, FR-003 | DONE |
| A4 | `404 maps to ModelNotFound with a models-list hint on the error path (T4)` | US4, FR-004 | DONE |
| U1 | `FinishReason.fromJson mapping table` (incl. unknown) | US2 | DONE |
