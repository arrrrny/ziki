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
        var buf: [8 * 1024 * 1024]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);

        var req_headers: [16]std.http.Header = undefined;
        var n: usize = 0;
        for (headers) |h| {
            if (n >= req_headers.len) break;
            req_headers[n] = .{ .name = h.name, .value = h.value };
            n += 1;
        }
        const m: std.http.Method = if (std.mem.eql(u8, method, "GET")) .GET else .POST;

        var client = std.http.Client{ .allocator = alloc };
        defer client.deinit();
        // Route through the configured proxy when set. We deliberately do NOT
        // call client.initDefaultProxies, so system-wide proxy env vars
        // (http_proxy / https_proxy / all_proxy) are ignored unless the user
        // explicitly configured one (FR-005).
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
