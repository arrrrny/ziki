# Bug Fix: HTTPS-over-HTTP-proxy fails (308); CONNECT+TLS fix does not compile

- **Slug**: https-proxy-connect-tunnel
- **Fixed**: 2026-08-23
- **Assessment**: ./assessment.md
- **Status**: applied

## Summary

The manual `CONNECT`+TLS workaround for HTTPS-over-HTTP-proxy compiled after a Zig 0.15.2 std-I/O API migration, but the proxied request **hung forever** reading the server's response. Two latent bugs remained after the compile fix: (1) the TLS stream reader/writer shared their ciphertext buffers with the `std.crypto.tls.Client`'s decrypted/plaintext buffers, and (2) the TLS `Client` never flushed the request to the socket for small payloads. Both are fixed; a live POST through `http://localhost:8890` now returns **200** (previously 308).

## Changes

| File | Change | Notes |
|------|--------|-------|
| `src/provider/transport.zig` | modified | Host extraction (`getHostAlloc`), full 0.15.2 I/O migration of `requestViaConnectTls`, distinct TLS/Client buffers, explicit flush after write. |

Detailed hunks:

1. **Host extraction** (the assessment's stated fix): `const target_host_raw = try uri.getHostAlloc(alloc); const target_host = try alloc.dupe(u8, target_host_raw); defer alloc.free(target_host);` — `getHostAlloc` may return a slice into `url`, so it is duped to an owned, freeable copy (mirrors `makeProxy`).

2. **0.15.2 I/O API migration** inside `requestViaConnectTls`:
   - Replaced `std.fmt.format(connect_w/req_w, "{d}", ...)` with `std.fmt.bufPrint(&buf, "{d}", ...)` + `writeAll` (the old `std.fmt.format` needs `std.io.Writer`; we use `std.Io.Writer`).
   - CONNECT: `stream.writer()` → `stream.writeAll(connect_req)`.
   - CONNECT read: `readUntilDelimiterOrEof`/`readAll` → `cir = connect_r.interface(); cir.takeDelimiter('\n')` / `cir.discardRemaining()`.
   - TLS response read: `readUntilDelimiterOrEof`/`readAtLeast`/`read(tmp)` → `takeDelimiter`/`readSliceAll`/`readSliceShort(&tmp)`.
   - `Client.init` args: `&tls_input.interface()` → `tls_input.interface()`; `&tls_output.interface` stays a pointer (writer `interface` is a **field**, not a method).
   - `parseStatusCode`: `parts.iterator()` → `var parts = std.mem.splitScalar(...); parts.next()`.
   - Header checks: `std.mem.startsWith(u8, std.ascii.toLower(line), ...)` → `std.ascii.startsWithIgnoreCase(line, ...)`; `indexOf` → `indexOfIgnoreCase`.
   - Stack overflow fix: the three `[8*1024*1024]u8` stack buffers (request/response scratch) → heap allocs with `defer alloc.free`, wrapped via `std.Io.Writer.fixed(buf)` (no `&`).

3. **Buffer de-aliasing (root fix for the hang):**
   ```zig
   var tls_read_buf:  [min_buffer_len]u8 = undefined; // stream Reader (ciphertext in)
   var tls_write_buf: [min_buffer_len]u8 = undefined; // stream Writer (ciphertext out)
   var tls_app_read_buf:  [min_buffer_len]u8 = undefined; // Client.reader buffer (decrypted)
   var tls_app_write_buf: [min_buffer_len]u8 = undefined; // Client.writer buffer (plaintext)
   ...
   .write_buffer = &tls_app_write_buf,
   .read_buffer  = &tls_app_read_buf,
   ```
   `Client.reader.buffer = options.read_buffer` and `Client.input = tls_input` (Client.zig:884/883). When the stream reader/writer used the **same** buffers as `read_buffer`/`write_buffer`, the two layers clobbered each other and the response read blocked on `readv` forever.

4. **Explicit flush (root fix for the hang):**
   ```zig
   _ = try tls_client.writer.writeAll(req_data);
   try tls_client.writer.flush();      // encrypt buffered plaintext into stream writer
   try tls_output.interface.flush();   // push ciphertext onto the wire
   ```
   The TLS `Client` buffers app data in its own large `write_buffer` and only drains when full; its `drain` only advances the underlying stream writer's buffer and never flushes to the socket (the handshake path calls `output.flush()` explicitly, the app-data path does not). For small requests nothing was encrypted or sent, so the server never responded.

## Diff Highlights (optional)

```zig
// before
const target_host = uri.host orelse return error.InvalidUrl;
...
var tls_client = try std.crypto.tls.Client.init(&tls_input.interface(), &tls_output.interface, .{ ... .write_buffer = &tls_write_buf, .read_buffer = &tls_read_buf });
_ = try tls_client.writer.writeAll(req_data);

// after
const target_host_raw = try uri.getHostAlloc(alloc);
const target_host = try alloc.dupe(u8, target_host_raw);
defer alloc.free(target_host);
...
var tls_app_read_buf:  [min_buffer_len]u8 = undefined;
var tls_app_write_buf: [min_buffer_len]u8 = undefined;
var tls_client = try std.crypto.tls.Client.init(tls_input.interface(), &tls_output.interface,
    .{ ... .write_buffer = &tls_app_write_buf, .read_buffer = &tls_app_read_buf });
_ = try tls_client.writer.writeAll(req_data);
try tls_client.writer.flush();
try tls_output.interface.flush();
```

## Tests Added or Updated

- Existing inline `transport.zig` tests (`makeProxy ...`, `HttpTransport with proxy stores parsed proxy`, etc.) still pass.
- No new unit test added for the tunnelled path (it requires a live proxy + TLS peer); validated via live e2e instead (see `test.md`).

## Local Verification

- Commands run:
  - `zig build` → success.
  - `zig build test` → all tests pass (exit 0).
  - Live e2e (standalone `scratch_proxy_test.zig` importing `transport.zig`, proxy `http://localhost:8890`):
    - `GET https://example.com/` → `PROXY_TEST_STATUS=200` + HTML body.
    - `POST https://api.kilo.ai/api/gateway/chat/completions` → `PROXY_TEST_STATUS=200` + valid `chat.completion` JSON (model `tencent/hy3`, content "Hi"). Previously this returned **308**.

## Deviations from Assessment

The assessment assumed the fix was **only** the host-extraction type error (`transport.zig:103`). In reality that was just the first of many compile errors, and the runtime tunnel was still broken after it compiled. Actual scope:

- Full Zig 0.15.2 `std.Io` API migration of `requestViaConnectTls` (fmt/CONNECT-read/TLS-read/`Client.init` args/`splitScalar`/case-insensitive header checks).
- Stack→heap migration of the 8 MiB scratch buffers to avoid a stack overflow segfault.
- Buffer **de-aliasing** (stream ciphertext buffers vs. Client plaintext buffers) — the actual cause of the post-compile hang.
- **Explicit flush** of the Client writer and the underlying stream writer — the other cause of the hang (small requests never transmitted).

None of these change the public `Transport`/`HttpTransport` API, so `FakeTransport` and existing call sites are unaffected.

## Follow-ups

- Replace `ca = .no_verification` with real CA verification for production hardening (in-code TODO).
- Add a unit test for host extraction over the CONNECT path; consider a local peek-proxy integration test for the tunnel.
- Clean up `scratch_proxy_test.zig` (scratch validation harness, not part of the build).
