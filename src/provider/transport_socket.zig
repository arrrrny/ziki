//! Local-socket agent-state transport (spec 012, ported from
//! `origin/012-socket-connection` onto master by issue #20).
//!
//! A `Transport` implementation that delivers the HTTP-shaped request over a
//! Unix domain socket, so a socket-bound Herdr listener needs no contract
//! change (FR-003). Selection is by URL scheme: `unix://` picks this transport,
//! `http://`/`https://` keep the HTTP transport, anything else is unsupported
//! and must fail fast at selection (FR-002/FR-007). The HTTP transport is not
//! modified (FR-004) and no third-party dependency is added (FR-005).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Transport = @import("transport.zig").Transport;
const Header = @import("transport.zig").Header;
const HttpResponse = @import("transport.zig").HttpResponse;

/// Which transport a Herdr API URL selects (FR-002).
pub const Selection = enum { socket, http, unsupported };

/// Classify by scheme prefix. `unix://` selects the socket transport; http(s)
/// keeps today's behavior (backward compatible, AS-2); every other scheme is
/// rejected so startup can fail fast with a clear message (FR-007).
pub fn selectByUrl(url: []const u8) Selection {
    if (std.mem.startsWith(u8, url, "unix://")) return .socket;
    if (std.mem.startsWith(u8, url, "http://")) return .http;
    if (std.mem.startsWith(u8, url, "https://")) return .http;
    return .unsupported;
}

/// Split a `unix://` URL into its socket path and HTTP request path
/// (FR-003: the request path is what the listener routes on).
///
/// `unix:///abs/socket.sock/api/v1/route` → socket `/abs/socket.sock`,
/// request `/api/v1/route`. The socket path is everything up to the contract
/// route marker `/api/`; without the marker the whole remainder is the socket
/// path and the request path is `/`. Returns null for a non-absolute path
/// (a Unix socket needs one).
pub const UnixUrl = struct { socket_path: []const u8, request_path: []const u8 };

pub fn splitUnixUrl(url: []const u8) ?UnixUrl {
    const prefix = "unix://";
    if (!std.mem.startsWith(u8, url, prefix)) return null;
    const rest = url[prefix.len..];
    if (rest.len == 0 or rest[0] != '/') return null;
    if (std.mem.indexOf(u8, rest, "/api/")) |idx| {
        if (idx > 0) return .{ .socket_path = rest[0..idx], .request_path = rest[idx..] };
    }
    return .{ .socket_path = rest, .request_path = "/" };
}

/// Real transport over a local Unix domain socket. Connects per request (like
/// HttpTransport's fresh client) so a restarted listener can never wedge a
/// later push. Connection failures propagate as clear errors; the Herdr
/// reporter swallows them so the goal loop is never blocked (FR-006).
pub const SocketTransport = struct {
    alloc: Allocator,
    socket_path: []const u8,

    pub fn init(alloc: Allocator, socket_path: []const u8) !SocketTransport {
        return .{ .alloc = alloc, .socket_path = try alloc.dupe(u8, socket_path) };
    }
    pub fn deinit(self: *SocketTransport) void {
        self.alloc.free(self.socket_path);
    }
    pub fn toTransport(self: *SocketTransport) Transport {
        return .{ .ctx = self, .vtable = &vtable };
    }
    const vtable = Transport.VTable{ .request = request };

    fn request(ctx: *anyopaque, alloc: Allocator, method: []const u8, url: []const u8, headers: []const Header, body: []const u8) anyerror!HttpResponse {
        const self: *SocketTransport = @ptrCast(@alignCast(ctx));
        // The transport is bound to its socket; the URL contributes only the
        // HTTP request path (so `{base_url}/api/...` URLs route correctly).
        const parts = splitUnixUrl(url) orelse return error.InvalidUrl;
        return post(alloc, self.socket_path, method, parts.request_path, headers, body);
    }
};

/// One HTTP-shaped request over `socket_path`. Fresh connection, closed after
/// one response (Connection: close), so response framing is header terminator
/// + read-to-EOF.
pub fn post(alloc: Allocator, socket_path: []const u8, method: []const u8, request_path: []const u8, headers: []const Header, body: []const u8) !HttpResponse {
    var stream = try std.net.connectUnixSocket(socket_path);
    defer stream.close();

    // FR-006: a stalled listener must surface as a swallowed reporter error,
    // never as a hung goal turn.
    const tv = std.posix.timeval{ .sec = 10, .usec = 0 };
    try std.posix.setsockopt(stream.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&tv));
    try std.posix.setsockopt(stream.handle, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&tv));

    // Build the exact wire shape an HTTP listener expects (FR-003): request
    // line, Host, caller headers (content-type), Content-Length, body.
    var req = try std.ArrayList(u8).initCapacity(alloc, 0);
    defer req.deinit(alloc);
    const w = req.writer(alloc);
    try w.print("{s} {s} HTTP/1.1\r\n", .{ method, request_path });
    try w.writeAll("Host: localhost\r\n");
    try w.writeAll("User-Agent: ziki/0.1\r\n");
    for (headers) |h| {
        try w.print("{s}: {s}\r\n", .{ h.name, h.value });
    }
    try w.print("Content-Length: {d}\r\n", .{body.len});
    try w.writeAll("Connection: close\r\n\r\n");
    try w.writeAll(body);
    try stream.writeAll(req.items);

    // Read the whole response (close-delimited), capped so a misbehaving
    // listener cannot grow memory without limit.
    var raw = try std.ArrayList(u8).initCapacity(alloc, 0);
    defer raw.deinit(alloc);
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = try stream.read(&buf);
        if (n == 0) break;
        if (raw.items.len + n > max_response_bytes) return error.ResponseTooLarge;
        try raw.appendSlice(alloc, buf[0..n]);
    }
    return parseResponse(alloc, raw.items);
}

/// Upper bound on a reporter response; real ACK bodies are tiny.
const max_response_bytes: usize = 1 << 20;

/// Parse status line + body from a close-delimited HTTP response.
pub fn parseResponse(alloc: Allocator, raw: []const u8) !HttpResponse {
    const sep = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return error.InvalidHttpResponse;
    const status_line = raw[0..sep];
    var parts = std.mem.splitScalar(u8, status_line, ' ');
    _ = parts.next() orelse return error.InvalidHttpResponse; // HTTP/1.1
    const code_str = parts.next() orelse return error.InvalidHttpResponse;
    const status = std.fmt.parseInt(u16, code_str, 10) catch return error.InvalidHttpResponse;
    var body = raw[sep + 4 ..];
    // Honour an exact Content-Length if the listener framed one.
    var it = std.mem.splitSequence(u8, raw[0..sep], "\r\n");
    while (it.next()) |line| {
        if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
            const val = std.mem.trim(u8, line["content-length:".len..], " ");
            const cl = std.fmt.parseInt(usize, val, 10) catch break;
            if (body.len >= cl) body = body[0..cl];
            break;
        }
    }
    return .{ .status = status, .body = try alloc.dupe(u8, body) };
}

// ---------------------------------------------------------------------------
// Tests (spec 012 acceptance scenarios).
// ---------------------------------------------------------------------------

test "socket URL selection: unix -> socket, http(s) -> http, else unsupported (U2)" {
    try std.testing.expectEqual(Selection.socket, selectByUrl("unix:///tmp/herdr.sock"));
    try std.testing.expectEqual(Selection.socket, selectByUrl("unix:///tmp/herdr.sock/api/v1/pane/report/agent"));
    try std.testing.expectEqual(Selection.http, selectByUrl("http://localhost:7878"));
    try std.testing.expectEqual(Selection.http, selectByUrl("https://herdr.local"));
    try std.testing.expectEqual(Selection.unsupported, selectByUrl("ftp://herdr.local"));
    try std.testing.expectEqual(Selection.unsupported, selectByUrl("localhost:7878"));
    try std.testing.expectEqual(Selection.unsupported, selectByUrl(""));
}

test "unix URL splits into socket path and request path (U3)" {
    const with_route = splitUnixUrl("unix:///tmp/herdr.sock/api/v1/pane/report/agent").?;
    try std.testing.expectEqualStrings("/tmp/herdr.sock", with_route.socket_path);
    try std.testing.expectEqualStrings("/api/v1/pane/report/agent", with_route.request_path);

    const bare = splitUnixUrl("unix:///tmp/herdr.sock").?;
    try std.testing.expectEqualStrings("/tmp/herdr.sock", bare.socket_path);
    try std.testing.expectEqualStrings("/", bare.request_path);

    // Non-absolute and non-unix URLs are invalid.
    try std.testing.expect(splitUnixUrl("unix://herdr.sock/api/x") == null);
    try std.testing.expect(splitUnixUrl("unix://") == null);
    try std.testing.expect(splitUnixUrl("http://localhost:7878") == null);
}

test "SocketTransport round-trips an HTTP-shaped request over a Unix socket (A4)" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_abs = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir_abs);
    const sock_path = try std.fs.path.join(alloc, &.{ dir_abs, "t.sock" });
    defer alloc.free(sock_path);

    // Listener thread: capture the request bytes, assert the HTTP shape, and
    // answer with an HTTP-shaped 200 (what Herdr's socket listener does).
    const addr = try std.net.Address.initUnix(sock_path);
    var listener = try addr.listen(.{});
    defer listener.deinit();
    const Listener = struct {
        fn run(srv: *std.net.Server, seen_request: *bool) void {
            const conn = srv.accept() catch return;
            defer conn.stream.close();
            var buf: [8192]u8 = undefined;
            var total: usize = 0;
            var head_end: usize = 0;
            while (total < buf.len) {
                const n = conn.stream.read(buf[total..]) catch return;
                if (n == 0) break;
                total += n;
                if (head_end == 0) {
                    if (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n")) |he| head_end = he;
                }
                if (head_end != 0) {
                    // Have head + the full Content-Length body? Then act.
                    const head = buf[0..head_end];
                    var lines = std.mem.splitSequence(u8, head, "\r\n");
                    const request_line = lines.next() orelse return;
                    if (!std.mem.eql(u8, request_line, "POST /api/v1/pane/report/agent HTTP/1.1")) return;
                    var has_host = false;
                    var has_ctype = false;
                    var content_len: usize = 0;
                    while (lines.next()) |line| {
                        if (std.ascii.startsWithIgnoreCase(line, "host:")) has_host = true;
                        if (std.ascii.startsWithIgnoreCase(line, "content-type: application/json")) has_ctype = true;
                        if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
                            content_len = std.fmt.parseInt(usize, std.mem.trim(u8, line["content-length:".len..], " "), 10) catch return;
                        }
                    }
                    if (!(has_host and has_ctype)) return;
                    if (total >= head_end + 4 + content_len) {
                        const req_body = buf[head_end + 4 .. head_end + 4 + content_len];
                        if (content_len == 2 and std.mem.eql(u8, req_body, "{}")) {
                            seen_request.* = true;
                        }
                        break;
                    }
                }
            }
            _ = conn.stream.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok") catch return;
        }
    };
    var seen = false;
    const th = try std.Thread.spawn(.{}, Listener.run, .{ &listener, &seen });
    defer th.join();

    var st = try SocketTransport.init(alloc, sock_path);
    defer st.deinit();
    const t = st.toTransport();
    const url = try std.fmt.allocPrint(alloc, "unix://{s}/api/v1/pane/report/agent", .{sock_path});
    defer alloc.free(url);
    const headers = [_]Header{.{ .name = "content-type", .value = "application/json" }};
    const resp = try t.request(alloc, "POST", url, &headers, "{}");
    defer alloc.free(resp.body);
    try std.testing.expectEqual(@as(u16, 200), resp.status);
    try std.testing.expectEqualStrings("ok", resp.body);
    try std.testing.expect(seen);
}

test "SocketTransport propagates a missing socket path as a clear error (U4)" {
    const alloc = std.testing.allocator;
    var st = try SocketTransport.init(alloc, "/nonexistent-dir-xyz/nope.sock");
    defer st.deinit();
    const t = st.toTransport();
    try std.testing.expectError(
        error.FileNotFound,
        t.request(alloc, "POST", "unix:///nonexistent-dir-xyz/nope.sock/api/v1/pane/report/agent", &.{}, "{}"),
    );
}

test "parseResponse reads status and Content-Length body" {
    const alloc = std.testing.allocator;
    const resp = try parseResponse(alloc, "HTTP/1.1 201 Created\r\nContent-Type: application/json\r\nContent-Length: 11\r\n\r\n{\"ok\":true}");
    defer alloc.free(resp.body);
    try std.testing.expectEqual(@as(u16, 201), resp.status);
    try std.testing.expectEqualStrings("{\"ok\":true}", resp.body);

    // Close-delimited without Content-Length: body is the remainder.
    const resp2 = try parseResponse(alloc, "HTTP/1.1 500 Internal Server Error\r\n\r\nboom");
    defer alloc.free(resp2.body);
    try std.testing.expectEqual(@as(u16, 500), resp2.status);
    try std.testing.expectEqualStrings("boom", resp2.body);

    // Garbage is a clear error, never a crash.
    try std.testing.expectError(error.InvalidHttpResponse, parseResponse(alloc, "not http"));
}
