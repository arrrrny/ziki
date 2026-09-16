const std = @import("std");
const compat = @import("../compat.zig");
const tr = @import("transport.zig");

const HttpTransport = tr.HttpTransport;
const Header = tr.Header;

// DEFERRED — TLS / HTTPS-through-proxy group.
//
// This file is intentionally NOT imported by `tests.zig`, so the default
// `zig build test` suite stays purely non-TLS (HTTP-proxy scenario). The test
// below exercises `requestViaConnectTls` (manual CONNECT + TLS), which is out of
// scope for the non-TLS scenario.
//
// It is deferred because of its SUBJECT (HTTPS/TLS), not because it fails — the
// test itself passes: the in-process proxy answers CONNECT with 503, so the
// TLS path surfaces `error.ProxyConnectFailed` before any handshake.
//
// Run it on its own when TLS is in scope:
//   zig test src/provider/transport_tls.zig

test "HttpTransport HTTPS-through-proxy fails on non-200 CONNECT" {
    // Same 0.16.0/macOS io limitation as the other loopback tests (spec 018
    // verification notes): a listener thread + client on one Threaded Io.
    if (comptime @import("builtin").os.tag == .macos) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    // In-process proxy that answers the CONNECT tunnel request with 503, so the
    // manual CONNECT+TLS path (requestViaConnectTls) must surface
    // error.ProxyConnectFailed rather than hang or mislead (FR-007 edge case).
    var address: std.Io.net.IpAddress = .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = 8792 } };
    var server = try address.listen(compat.io(), .{ .reuse_address = true });
    defer server.deinit(compat.io());
    const Proxy = struct {
        fn run(s: *std.Io.net.Server) void {
            const io = compat.io();
            const conn = s.accept(io) catch return;
            defer conn.close(io);
            var rbuf: [4096]u8 = undefined;
            var wbuf: [4096]u8 = undefined;
            var r = conn.reader(io, &rbuf);
            const ri = &r.interface;
            var w = conn.writer(io, &wbuf);
            const wi = &w.interface;
            // Read the CONNECT request fully before replying.
            var buf: [4096]u8 = undefined;
            var total: usize = 0;
            while (total < buf.len) {
                const n = ri.readSliceShort(buf[total..]) catch return;
                if (n == 0) return;
                total += n;
                if (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n") != null) break;
            }
            const resp = "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\n\r\n";
            wi.writeAll(resp) catch return;
            wi.flush() catch return;
        }
    };
    var th = try std.Thread.spawn(.{}, Proxy.run, .{&server});
    defer th.join();

    var transport = try HttpTransport.init(alloc, "http://127.0.0.1:8792");
    defer transport.deinit();
    const t = transport.toTransport();
    // HTTPS target + proxy => requestViaConnectTls => CONNECT to 8792 => 503.
    const res = t.request(alloc, "GET", "https://127.0.0.1:9/ignored", &[_]Header{}, "");
    try std.testing.expectError(error.ProxyConnectFailed, res);
}
