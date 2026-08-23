# Bug Assessment: HTTPS-over-HTTP-proxy fails (308); CONNECT+TLS fix does not compile

- **Slug**: https-proxy-connect-tunnel
- **Created**: 2026-08-23
- **Source**: pasted text (conversation investigation; no external report)
- **Verdict**: valid
- **Severity**: high

## Report (verbatim or summarized)

User asked to test whether the configured localhost proxy works for ziki. Investigation found:

- The proxy server at `http://localhost:8890` is itself healthy: `curl -x http://localhost:8890 https://api.kilo.ai/api/gateway/chat/completions` with Bearer auth returns **200** + a real kilo completion (model `tencent/hy3`). GET → 405, POST → 200. `curl` succeeds through the proxy with any User-Agent (UA ruled out as a cause).
- A direct (no-proxy) Zig POST to kilo returns **200**, so ziki's request payload is valid.
- A proxied Zig POST to kilo returns **308 "Redirecting..."** (and `TooManyHttpRedirects` when following redirects). The same request via `curl` returns 200.
- A peek proxy proved the root cause: ziki's `std.http.Client` issues `CONNECT api.kilo.ai:443` correctly, then sends the actual `POST https://api.kilo.ai/...` as a **plaintext absolute-URI forward on a separate connection** instead of over the TLS tunnel — Vercel/Cloudflare fronts then 308-redirect it.
- The user subsequently implemented a manual `CONNECT` + TLS workaround (`requestViaConnectTls`). **That workaround does not compile**, so `zig build` currently fails.

## Symptom

Goals routed through the configured HTTPS proxy never complete (provider returns a 308 redirect instead of 200), so ziki cannot run behind the proxy. The intended fix (manual CONNECT+TLS tunnel) is present but fails to compile, leaving `zig build` red for everyone.

## Reproduction

1. Ensure proxy is configured (`~/.config/ziki/config.json` has `"proxy": "http://localhost:8890"`, or set `ZIKI_PROXY`).
2. Run a minimal goal: `ZIKI_PROVIDER=... ZIKI_API_KEY=... ZIKI_ENDPOINT=https://api.kilo.ai/api/gateway/chat/completions ZIKI_MODEL=... ./zig-out/bin/ziki "<objective>"`.
3. Observe: goal fails / provider returns 308, instead of completing.
4. Run `zig build` to see the current blocker:
   ```
   src/provider/transport.zig:103:65: error: expected type '[]const u8', found 'Uri.Component'
   ```

## Suspected Code Paths

- `src/provider/transport.zig:84-92` — URL parsing; `const target_host = uri.host orelse ...` makes `target_host` a `?std.Uri.Component` union, not a `[]const u8`.
- `src/provider/transport.zig:99-105` — the call site that passes `target_host` (a `std.Uri.Component`) into `requestViaConnectTls`, which expects `[]const u8`. This is the build failure.
- `src/provider/transport.zig:133-142` — `requestViaConnectTls` signature: `target_host: []const u8`.
- `src/provider/transport.zig:317-334` — `makeProxy` extracts the host correctly via `uri.getHostAlloc(alloc)` returning `[]const u8`; this is the pattern the broken call site should follow.
- `src/config/config.zig:46,61,71` — proxy URL is read from env `ZIKI_PROXY` then the config file and stored in `Config.proxy`; it is passed to `HttpTransport.init` and applied to every per-request client.

## Root Cause Hypothesis

Two layered causes. **Primary (original bug):** Zig `std.http.Client` 0.15.2 mishandles HTTPS-over-HTTP-proxy — after `CONNECT`, it forwards the request as a plaintext absolute-URI on a separate connection rather than over the established TLS tunnel, so Cloudflare/Vercel fronts return 308. This is a known `std.http` limitation. The manual `requestViaConnectTls` workaround was added to bypass it. **Secondary (current blocker):** that workaround's call site passes `uri.host` (a `std.Uri.Component` union) instead of a `[]const u8` host string, so the project fails to compile. Confidence: **high** — the compile error was reproduced directly via `zig build` (single error at `transport.zig:103`).

## Proposed Remediation

**Preferred**: Extract the host as a `[]const u8` from the parsed URI before the call, mirroring `makeProxy`'s use of `std.Uri.getHostAlloc`. Replace `const target_host = uri.host orelse return error.InvalidUrl;` with `const target_host = try uri.getHostAlloc(alloc);` and free the resulting slice after the request completes, then pass `target_host` into `requestViaConnectTls`. This resolves the single type error at `transport.zig:103`. After it compiles, rebuild and run a live goal through `http://localhost:8890` to confirm the HTTPS tunnel returns 200 and the goal reaches status `completed` (SC-001).

**Alternatives**:
- Use `std.Uri.Component.toRaw(uri.host.?, buf[0..])` to avoid an allocation — costs a fixed-size buffer and an extra `orelse` guard.
- Revert the manual CONNECT+TLS workaround and instead upgrade Zig to a release where `std.http` handles proxy+TLS correctly (heavier; risks other breakage).

**Files likely to change**:
- `src/provider/transport.zig` (the host extraction + matching `free`; possibly more if further compile errors surface beyond the first).

**Tests to add or update**:
- Extend the inline `transport.zig` tests with a unit case for the HTTPS+proxy path host extraction (or a "HttpTransport selects CONNECT path for https+proxy" test) using a local peek proxy if feasible.
- End-to-end: run a minimal goal through `:8890` and assert status `completed`.

## Risks & Considerations

- `ca = .no_verification` disables TLS cert verification on the tunnel (flagged by an in-code TODO). Acceptable for a dev proxy front; production hardening needs real CA verification.
- The manual HTTP/1.1 parser (chunked / Content-Length / EOF) is more fragile than `std.http`; the direct (no-proxy) path still uses `std.http.Client`, limiting blast radius.
- Per-request fresh-client design is preserved by the workaround.

## Open Questions

- After fixing the type error, does `zig build` fully pass, or are there further errors deeper in the TLS/HTTP path? (Could only verify the first compile error.) [NEEDS CLARIFICATION / verify in bug-fix phase]
- Is the `:8890` Cloudflare tunnel front currently up? (Healthy during investigation; re-check before the live e2e test.)
