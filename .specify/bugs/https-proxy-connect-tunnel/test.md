# Bug Verification: HTTPS-over-HTTP-proxy fails (308); CONNECT+TLS fix does not compile

- **Slug**: https-proxy-connect-tunnel
- **Tested**: 2026-08-23
- **Assessment**: ./assessment.md
- **Fix**: ./fix.md
- **Result**: verified

## Summary

The original symptom — a proxied HTTPS request to kilo returning **308** (redirect) and stalling the goal loop — no longer reproduces. After the fix, a live `CONNECT`+TLS tunnel through `http://localhost:8890` returns **200** for both `https://example.com` (generic) and `https://api.kilo.ai/api/gateway/chat/completions` (the real provider). `zig build` and `zig build test` are green.

## Checks Performed

| Check | Command / Action | Result | Notes |
|-------|------------------|--------|-------|
| Build | `zig build` | pass | no compile errors; previously red at `transport.zig:103` |
| Unit tests | `zig build test` | pass | all inline `transport.zig` tests pass (exit 0) |
| Live e2e (generic) | standalone harness → `GET https://example.com/` via `http://localhost:8890` | pass | `PROXY_TEST_STATUS=200` + HTML body |
| Live e2e (provider) | standalone harness → `POST https://api.kilo.ai/api/gateway/chat/completions` via `http://localhost:8890` | pass | `PROXY_TEST_STATUS=200` + valid `chat.completion` JSON (model `tencent/hy3`, content "Hi"). This is the exact request that previously returned **308** |
| Regression (direct) | `curl -x http://localhost:8890 https://api.kilo.ai/...` POST | pass | still 200 (proxy itself healthy; confirms only ziki's path was broken) |
| Lint / type-check | `zig build` (strict) | pass | no warnings surfaced |

## Output Excerpts

```
# before the fix (assessment, reproduced)
POST https://api.kilo.ai/... via proxy  -> 308 "Redirecting..."

# after the fix (live e2e, this session)
[connect] HTTP/1.0 200 Connection established
[write ] 581 bytes of TLS request
PROXY_TEST_STATUS=200
PROXY_TEST_BODY={"id":"gen-...","object":"chat.completion","model":"tencent/hy3","choices":[{"message":{"role":"assistant","content":"Hi"}}]}
```

## Residual Risks

- `ca = .no_verification` disables cert verification on the tunnel (in-code TODO). Fine for a dev proxy; not production-safe.
- The manual HTTP/1.1 response parser (chunked / Content-Length / EOF) is more fragile than `std.http`; the direct (no-proxy) path still uses `std.http.Client`, so blast radius is limited to the proxy+HTTPS case.
- Full end-to-end **goal** run (config → provider → agent loop) was validated at the transport level (the bug's locus). A run of a complete goal through the proxy is a recommended follow-up smoke test (handled separately in the commit/PR re-test step).

## Recommendation

Close the bug — verified end-to-end at the transport layer. The 308 is gone and the tunnel returns 200 for both a generic host and the real provider. A post-merge smoke test of an actual `ziki` goal through `http://localhost:8890` is still advisable as a final confidence check.
