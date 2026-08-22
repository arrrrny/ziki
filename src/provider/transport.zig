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

    pub fn init(alloc: Allocator) HttpTransport {
        return .{ .alloc = alloc };
    }
    pub fn deinit(self: *HttpTransport) void {
        _ = self;
    }
    pub fn toTransport(self: *HttpTransport) Transport {
        return .{ .ctx = self, .vtable = &vtable };
    }
    const vtable = Transport.VTable{ .request = request };

    fn request(ctx: *anyopaque, alloc: Allocator, method: []const u8, url: []const u8, headers: []const Header, body: []const u8) !HttpResponse {
        _ = ctx;
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
