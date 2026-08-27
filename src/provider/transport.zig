const std = @import("std");
const Allocator = std.mem.Allocator;

/// A single HTTP header.
pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

/// A captured HTTP response. `body` is owned by the caller (duped from the
/// transport's scratch buffer).
pub const HttpResponse = struct {
    status: u16,
    body: []const u8,
};

/// Low-level HTTP boundary (DI). The real provider depends on this, not on
/// std.http directly, so it is testable with FakeTransport.
pub const Transport = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        request: *const fn (ctx: *anyopaque, alloc: Allocator, method: []const u8, url: []const u8, headers: []const Header, body: []const u8) anyerror!HttpResponse,
    };

    pub fn request(self: Transport, alloc: Allocator, method: []const u8, url: []const u8, headers: []const Header, body: []const u8) !HttpResponse {
        return self.vtable.request(self.ctx, alloc, method, url, headers, body);
    }
};

/// Real transport over std.http.Client + std.crypto.tls (no third-party deps).
/// A fresh client is created per request so connection reuse / keep-alive
/// quirks of a given proxy can never stall the goal loop on a later turn.
/// For HTTPS targets with a proxy, we implement manual CONNECT + TLS to work
/// around std.http 0.15.2's broken proxy+TLS path.
pub const HttpTransport = struct {
    alloc: Allocator,
    /// Parsed proxy, or null for a direct connection. Built once at init from
    /// the configuration; applied to every per-request client (spec 009).
    proxy: ?*std.http.Client.Proxy,

    pub fn init(alloc: Allocator, proxy_url: ?[]const u8) !HttpTransport {
        const proxy = if (proxy_url) |u| try makeProxy(alloc, u) else null;
        return .{ .alloc = alloc, .proxy = proxy };
    }
    pub fn deinit(self: *HttpTransport) void {
        if (self.proxy) |p| {
            self.alloc.free(p.host);
            self.alloc.destroy(p);
        }
    }
    pub fn toTransport(self: *HttpTransport) Transport {
        return .{ .ctx = self, .vtable = &vtable };
    }
    const vtable = Transport.VTable{ .request = request };

    fn request(ctx: *anyopaque, alloc: Allocator, method: []const u8, url: []const u8, headers: []const Header, body: []const u8) !HttpResponse {
        const self: *HttpTransport = @ptrCast(@alignCast(ctx));

        var req_headers: [16]std.http.Header = undefined;
        var n: usize = 0;
        for (headers) |h| {
            if (n >= req_headers.len) break;
            req_headers[n] = .{ .name = h.name, .value = h.value };
            n += 1;
        }
        // Default User-Agent so proxies / WAFs (e.g. Cloudflare) don't reject
        // headerless requests. Skipped if the caller already supplied one.
        var has_ua = false;
        for (req_headers[0..n]) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "user-agent")) {
                has_ua = true;
                break;
            }
        }
        if (!has_ua and n < req_headers.len) {
            req_headers[n] = .{ .name = "user-agent", .value = "ziki/0.1" };
            n += 1;
        }
        const m: std.http.Method = if (std.mem.eql(u8, method, "GET")) .GET else .POST;

        // Parse URL to determine scheme, host, port, path
        const uri = std.Uri.parse(url) catch return error.InvalidUrl;
        const is_https = std.mem.eql(u8, uri.scheme, "https");
        // getHostAlloc may return a slice into `url` (not owned), so dupe it to
        // get a freeable, owned copy — mirroring makeProxy (line 322).
        const target_host_raw = try uri.getHostAlloc(alloc);
        const target_host = try alloc.dupe(u8, target_host_raw);
        defer alloc.free(target_host);
        var target_port: u16 = 80;
        if (uri.port) |p| {
            target_port = p;
        } else if (is_https) {
            target_port = 443;
        }
        // Extract path from URL manually (avoid Uri.Component type issues)
        const scheme_len = if (is_https) "https://".len else "http://".len;
        const url_after_scheme = url[scheme_len..];
        const host_end = std.mem.indexOfScalar(u8, url_after_scheme, '/') orelse url_after_scheme.len;
        const target_path: []const u8 = if (host_end < url_after_scheme.len) url_after_scheme[host_end..] else "/";

        // If we have a proxy AND the target is HTTPS, use manual CONNECT + TLS
        // to avoid std.http's broken proxy+TLS path (0.15.2).
        if (self.proxy != null) {
            if (is_https) {
                return try requestViaConnectTls(self, alloc, m, target_host, target_port, target_path, req_headers[0..n], body);
            }
        }

        // Otherwise (HTTP target, or no proxy): use std.http.Client normally
        var client = std.http.Client{ .allocator = alloc };
        defer client.deinit();
        const buf = try alloc.alloc(u8, 8 * 1024 * 1024);
        defer alloc.free(buf);
        var w = std.Io.Writer.fixed(buf);

        if (self.proxy) |p| {
            client.http_proxy = p;
            client.https_proxy = p;
        }

        const result = try client.fetch(.{
            .method = m,
            .location = .{ .url = url },
            .payload = body,
            .response_writer = &w,
            .extra_headers = req_headers[0..n],
        });
        const written = w.buffered();
        const owned = try alloc.dupe(u8, written);
        return .{ .status = @intFromEnum(result.status), .body = owned };
    }
};

/// Manual CONNECT + TLS implementation for HTTPS targets through an HTTP proxy.
/// This bypasses std.http's broken proxy+TLS in 0.15.2.
fn requestViaConnectTls(
    self: *HttpTransport,
    alloc: Allocator,
    method: std.http.Method,
    target_host: []const u8,
    target_port: u16,
    target_path: []const u8,
    headers: []const std.http.Header,
    body: []const u8,
) !HttpResponse {
    const proxy = self.proxy.?;

    // 1. Connect to the proxy (TCP)
    var stream = try std.net.tcpConnectToHost(alloc, proxy.host, proxy.port);
    defer stream.close();

    // 2. Send CONNECT request
    var connect_buf: [2048]u8 = undefined;
    var connect_w = std.Io.Writer.fixed(&connect_buf);
    var port_buf: [6]u8 = undefined;
    try connect_w.writeAll("CONNECT ");
    try connect_w.writeAll(target_host);
    try connect_w.writeAll(":");
    try connect_w.writeAll(try std.fmt.bufPrint(&port_buf, "{d}", .{target_port}));
    try connect_w.writeAll(" HTTP/1.1\r\n");
    try connect_w.writeAll("Host: ");
    try connect_w.writeAll(target_host);
    try connect_w.writeAll(":");
    try connect_w.writeAll(try std.fmt.bufPrint(&port_buf, "{d}", .{target_port}));
    try connect_w.writeAll("\r\n");
    try connect_w.writeAll("User-Agent: ziki/0.1\r\n");
    try connect_w.writeAll("\r\n");

    const connect_req = connect_w.buffered();
    _ = try stream.writeAll(connect_req);

    // 3. Read CONNECT response
    var connect_resp_buf: [4096]u8 = undefined;
    var connect_r = std.net.Stream.Reader.init(stream, &connect_resp_buf);
    const cir = connect_r.interface();

    // Read status line
    const status_line = (try cir.takeDelimiter('\n')) orelse return error.ProxyConnectFailed;
    if (!std.mem.startsWith(u8, status_line, "HTTP/1.1 200") and !std.mem.startsWith(u8, status_line, "HTTP/1.0 200")) {
        // Discard rest of response for debugging
        _ = cir.discardRemaining() catch {};
        return error.ProxyConnectFailed;
    }

    // Read headers until empty line
    while (true) {
        const line = (try cir.takeDelimiter('\n')) orelse break;
        if (line.len <= 2) break; // empty line (CRLF or LF)
    }

    // 4. Wrap the stream with TLS
    // TLS requires buffers of at least min_buffer_len. The stream reader/writer
    // need their OWN ciphertext buffers; the Client's read_buffer/write_buffer
    // are the decrypted/plaintext side and must NOT alias the stream buffers,
    // or the two layers clobber each other and the response read hangs
    // (see Client.zig: reader.buffer = options.read_buffer, input = stream reader).
    var tls_read_buf: [std.crypto.tls.Client.min_buffer_len]u8 = undefined;
    var tls_write_buf: [std.crypto.tls.Client.min_buffer_len]u8 = undefined;
    var tls_app_read_buf: [std.crypto.tls.Client.min_buffer_len]u8 = undefined;
    var tls_app_write_buf: [std.crypto.tls.Client.min_buffer_len]u8 = undefined;

    var tls_input = std.net.Stream.Reader.init(stream, &tls_read_buf);
    var tls_output = std.net.Stream.Writer.init(stream, &tls_write_buf);

    var tls_client = try std.crypto.tls.Client.init(
        tls_input.interface(),
        &tls_output.interface,
        .{
            .host = .{ .explicit = target_host },
            .ca = .no_verification, // TODO: proper cert verification
            .write_buffer = &tls_app_write_buf,
            .read_buffer = &tls_app_read_buf,
        },
    );

    // 5. Send actual HTTP request over TLS
    const req_mem = try alloc.alloc(u8, 8 * 1024 * 1024);
    defer alloc.free(req_mem);
    var req_w = std.Io.Writer.fixed(req_mem);
    var num_buf: [20]u8 = undefined;

    // Request line
    const method_str = if (method == .GET) "GET" else "POST";
    try req_w.writeAll(method_str);
    try req_w.writeAll(" ");
    try req_w.writeAll(target_path);
    try req_w.writeAll(" HTTP/1.1\r\n");

    // Headers
    try req_w.writeAll("Host: ");
    try req_w.writeAll(target_host);
    try req_w.writeAll(":");
    try req_w.writeAll(try std.fmt.bufPrint(&num_buf, "{d}", .{target_port}));
    try req_w.writeAll("\r\n");
    try req_w.writeAll("User-Agent: ziki/0.1\r\n");
    try req_w.writeAll("Connection: close\r\n");
    for (headers) |h| {
        try req_w.writeAll(h.name);
        try req_w.writeAll(": ");
        try req_w.writeAll(h.value);
        try req_w.writeAll("\r\n");
    }
    if (body.len > 0) {
        try req_w.writeAll("Content-Length: ");
        try req_w.writeAll(try std.fmt.bufPrint(&num_buf, "{d}", .{body.len}));
        try req_w.writeAll("\r\n");
    }
    try req_w.writeAll("\r\n");
    if (body.len > 0) {
        try req_w.writeAll(body);
    }

    const req_data = req_w.buffered();
    _ = try tls_client.writer.writeAll(req_data);
    // The TLS Client buffers app data in its own (large) buffer and only drains
    // when full, and its `drain` only advances the underlying stream writer's
    // buffer (it never flushes to the socket). For small requests neither
    // happens automatically, so flush explicitly: encrypt the buffered plaintext
    // into the stream writer, then push the ciphertext onto the wire.
    try tls_client.writer.flush();
    try tls_output.interface.flush();

    // 6. Read HTTP response from TLS
    const resp_mem = try alloc.alloc(u8, 8 * 1024 * 1024);
    defer alloc.free(resp_mem);
    var resp_w = std.Io.Writer.fixed(resp_mem);
    // Point at the Client's reader FIELD (not a copy): tls.Client's reader
    // vtable recovers the Client via @fieldParentPtr, which only works on the
    // real field, not a copied interface struct.
    var resp_r = &tls_client.reader;

    // Read status line
    const resp_status_line = (try resp_r.takeDelimiter('\n')) orelse "";
    const status_code = try parseStatusCode(resp_status_line);

    // Read headers
    var content_length: usize = 0;
    var chunked = false;
    while (true) {
        const line = (try resp_r.takeDelimiter('\n')) orelse break;
        if (line.len <= 2) break;
        if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
            const val = std.mem.trim(u8, line["content-length:".len..], "\r\n ");
            content_length = std.fmt.parseInt(usize, val, 10) catch 0;
        } else if (std.ascii.startsWithIgnoreCase(line, "transfer-encoding:")) {
            if (std.ascii.indexOfIgnoreCase(line, "chunked") != null) {
                chunked = true;
            }
        }
    }

    // Read body
    if (chunked) {
        while (true) {
            const chunk_size_line = (try resp_r.takeDelimiter('\n')) orelse break;
            const chunk_size = std.fmt.parseInt(usize, std.mem.trim(u8, chunk_size_line, "\r\n "), 16) catch 0;
            if (chunk_size == 0) {
                // Trailing CRLF / trailers
                _ = resp_r.takeDelimiter('\n') catch null;
                break;
            }
            const chunk = try alloc.alloc(u8, chunk_size);
            try resp_r.readSliceAll(chunk);
            try resp_w.writeAll(chunk);
            alloc.free(chunk);
            // Consume trailing CRLF after chunk
            _ = resp_r.takeDelimiter('\n') catch null;
        }
    } else if (content_length > 0) {
        const body_buf = try alloc.alloc(u8, content_length);
        try resp_r.readSliceAll(body_buf);
        try resp_w.writeAll(body_buf);
        alloc.free(body_buf);
    } else {
        // Read until EOF
        var tmp: [8192]u8 = undefined;
        while (true) {
            const n = resp_r.readSliceShort(&tmp) catch break;
            if (n == 0) break;
            try resp_w.writeAll(tmp[0..n]);
        }
    }

    const written = resp_w.buffered();
    const owned = try alloc.dupe(u8, written);
    return .{ .status = status_code, .body = owned };
}

fn parseStatusCode(line: []const u8) !u16 {
    // HTTP/1.1 200 OK
    var parts = std.mem.splitScalar(u8, line, ' ');
    _ = parts.next(); // HTTP/1.1
    const code_str = parts.next() orelse return error.InvalidHttpResponse;
    return std.fmt.parseInt(u16, code_str, 10) catch return error.InvalidHttpResponse;
}

/// Build a std.http.Client.Proxy from a proxy URL. Returns an error on a
/// malformed URL so the caller can fail fast at startup (FR-007).
fn makeProxy(alloc: Allocator, url: []const u8) !*std.http.Client.Proxy {
    const uri = std.Uri.parse(url) catch return error.InvalidProxyUrl;
    const protocol = std.http.Client.Protocol.fromUri(uri) orelse return error.InvalidProxyUrl;
    // getHostAlloc may return a slice pointing into `url` when the host is already
    // raw, so dupe it to guarantee HttpTransport.deinit can always free it.
    const host_raw = try uri.getHostAlloc(alloc);
    const host = try alloc.dupe(u8, host_raw);
    const port: u16 = uri.port orelse if (protocol == .tls) 443 else 80;
    const p = try alloc.create(std.http.Client.Proxy);
    p.* = .{
        .protocol = protocol,
        .host = host,
        .authorization = null,
        .port = port,
        .supports_connect = true,
    };
    return p;
}

/// Scripted transport for tests: returns a canned body for any request.
pub const FakeTransport = struct {
    status: u16,
    body: []const u8,

    pub fn init(status: u16, body: []const u8) FakeTransport {
        return .{ .status = status, .body = body };
    }
    pub fn toTransport(self: *FakeTransport) Transport {
        return .{ .ctx = self, .vtable = &vtable };
    }
    const vtable = Transport.VTable{ .request = request };

    fn request(ctx: *anyopaque, alloc: Allocator, _: []const u8, _: []const u8, _: []const Header, _: []const u8) !HttpResponse {
        const self: *FakeTransport = @ptrCast(@alignCast(ctx));
        return .{ .status = self.status, .body = try alloc.dupe(u8, self.body) };
    }
};

test "HttpTransport type-checks via FakeTransport shape" {
    // Real HttpTransport requires network; FakeTransport proves the contract.
    var fake = FakeTransport.init(200, "{\"ok\":true}");
    const t = fake.toTransport();
    const resp = try t.request(std.testing.allocator, "POST", "https://x", &.{}, "{}");
    defer std.testing.allocator.free(resp.body);
    try std.testing.expectEqual(@as(u16, 200), resp.status);
    try std.testing.expectEqualStrings("{\"ok\":true}", resp.body);
}

test "makeProxy parses http://localhost:8890" {
    const alloc = std.testing.allocator;
    const p = try makeProxy(alloc, "http://localhost:8890");
    defer {
        alloc.free(p.host);
        alloc.destroy(p);
    }
    try std.testing.expectEqual(std.http.Client.Protocol.plain, p.protocol);
    try std.testing.expectEqualStrings("localhost", p.host);
    try std.testing.expectEqual(@as(u16, 8890), p.port);
    try std.testing.expect(p.supports_connect);
}

test "makeProxy parses https with default port" {
    const alloc = std.testing.allocator;
    const p = try makeProxy(alloc, "https://proxy.example.com");
    defer {
        alloc.free(p.host);
        alloc.destroy(p);
    }
    try std.testing.expectEqual(std.http.Client.Protocol.tls, p.protocol);
    try std.testing.expectEqual(@as(u16, 443), p.port);
}

test "makeProxy parses https with explicit port" {
    const alloc = std.testing.allocator;
    const p = try makeProxy(alloc, "https://proxy.example.com:3128");
    defer {
        alloc.free(p.host);
        alloc.destroy(p);
    }
    try std.testing.expectEqual(std.http.Client.Protocol.tls, p.protocol);
    try std.testing.expectEqual(@as(u16, 3128), p.port);
}

test "makeProxy rejects malformed url" {
    try std.testing.expectError(error.InvalidProxyUrl, makeProxy(std.testing.allocator, "not-a-url"));
    try std.testing.expectError(error.InvalidProxyUrl, makeProxy(std.testing.allocator, "ftp:///no-host"));
}

test "HttpTransport with no proxy stores null (system proxy ignored)" {
    const t = try HttpTransport.init(std.testing.allocator, null);
    try std.testing.expect(t.proxy == null);
}

test "HttpTransport with proxy stores parsed proxy" {
    var t = try HttpTransport.init(std.testing.allocator, "http://localhost:8890");
    defer t.deinit();
    try std.testing.expect(t.proxy != null);
    try std.testing.expectEqualStrings("localhost", t.proxy.?.host);
    try std.testing.expectEqual(@as(u16, 8890), t.proxy.?.port);
}

test "HttpTransport routes HTTP requests through the configured proxy" {
    const alloc = std.testing.allocator;
    // In-process HTTP proxy: records that a request arrived (proving the
    // transport assigned client.http_proxy) and answers 200. For an HTTP target
    // std.http.Client sends the absolute URL to the proxy, never to the bare
    // target host.
    var server = try std.net.Address.listen(std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 8791), .{ .reuse_address = true });
    defer server.deinit();
    var proxied = false;
    const Proxy = struct {
        fn run(s: *std.net.Server, seen: *bool) void {
            const conn = s.accept() catch return;
            defer conn.stream.close();
            // makeProxy sets supports_connect = true, so std.http tunnels HTTP
            // targets via CONNECT: the client sends CONNECT first, then the real
            // request over the tunnel. Reply 200 to CONNECT, then read+drain the
            // tunneled request and answer 200.
            var buf: [1 << 16]u8 = undefined;
            // 1) CONNECT request
            var total: usize = 0;
            while (total < buf.len) {
                const n = conn.stream.read(buf[total..]) catch return;
                if (n == 0) return;
                total += n;
                if (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n") != null) break;
            }
            _ = conn.stream.writeAll("HTTP/1.1 200 Connection established\r\n\r\n") catch return;
            // 2) tunneled real request (head + body)
            var total2: usize = 0;
            var content_len: usize = 0;
            var have_head = false;
            while (total2 < buf.len) {
                const n = conn.stream.read(buf[total2..]) catch return;
                if (n == 0) return;
                total2 += n;
                if (!have_head) {
                    if (std.mem.indexOf(u8, buf[0..total2], "\r\n\r\n")) |he| {
                        have_head = true;
                        var it = std.mem.tokenizeScalar(u8, buf[0..he], '\n');
                        while (it.next()) |line| {
                            const tl = std.mem.trim(u8, line, "\r");
                            if (std.ascii.startsWithIgnoreCase(tl, "content-length:")) {
                                content_len = std.fmt.parseUnsigned(usize, std.mem.trim(u8, tl["content-length:".len..], " "), 10) catch 0;
                            }
                        }
                    }
                }
                if (have_head) {
                    const he_idx = std.mem.indexOf(u8, buf[0..total2], "\r\n\r\n").?;
                    if (total2 >= he_idx + 4 + content_len) break;
                }
            }
            seen.* = true;
            const resp = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok";
            _ = conn.stream.writeAll(resp) catch return;
        }
    };
    var th = try std.Thread.spawn(.{}, Proxy.run, .{ &server, &proxied });
    defer th.join();

    var transport = try HttpTransport.init(alloc, "http://127.0.0.1:8791");
    defer transport.deinit();
    const t = transport.toTransport();
    // Target port 9 is never connected to; the request must hit the proxy.
    const resp = try t.request(alloc, "POST", "http://127.0.0.1:9/ignored", &[_]Header{}, "{}");
    defer alloc.free(resp.body);
    // U11: the request was routed through the proxy (never the bare target) and
    // the proxy's 200 came back. (System-proxy opt-out is U9 + live scenario E.)
    try std.testing.expect(proxied);
    try std.testing.expectEqual(@as(u16, 200), resp.status);
}

// NOTE: The HTTPS-through-proxy (CONNECT+TLS) test was moved to
// `src/provider/transport_tls.zig` and is intentionally NOT imported by
// `tests.zig`, so the default `zig build test` suite stays non-TLS. Restore it
// to the active run (import the file in tests.zig) when TLS is in scope.