const std = @import("std");
const Allocator = std.mem.Allocator;
const state = @import("state.zig");
const Transport = @import("../provider/transport.zig").Transport;
const Header = @import("../provider/transport.zig").Header;
const HttpResponse = @import("../provider/transport.zig").HttpResponse;

/// Real Herdr reporter: serializes `PaneReportParams` to the contract §2 JSON
/// body and POSTs it to `${base_url}/api/v1/pane/report/agent` over an injected
/// `Transport` (real `HttpTransport` or `FakeTransport` in tests).
pub const HerdrHttpClient = struct {
    alloc: Allocator,
    transport: Transport,
    base_url: []const u8,

    pub fn init(alloc: Allocator, transport: Transport, base_url: []const u8) HerdrHttpClient {
        return .{ .alloc = alloc, .transport = transport, .base_url = base_url };
    }

    /// Adapt this client into the `HerdrReporter` DI interface so it can be
    /// plugged into `StatePublisher`.
    pub fn toReporter(self: *HerdrHttpClient) state.HerdrReporter {
        return .{ .ctx = self, .vtable = &vtable };
    }
    const vtable = state.HerdrReporter.VTable{ .report = report };

    fn report(ctx: *anyopaque, alloc: Allocator, params: state.PaneReportParams) !void {
        const self: *HerdrHttpClient = @ptrCast(@alignCast(ctx));
        return self.doReport(alloc, params);
    }

    fn doReport(self: *HerdrHttpClient, alloc: Allocator, params: state.PaneReportParams) !void {
        const url = try std.fmt.allocPrint(alloc, "{s}/api/v1/pane/report/agent", .{self.base_url});
        defer alloc.free(url);
        const body = try serialize(alloc, params);
        defer alloc.free(body);
        const headers = [_]Header{.{ .name = "content-type", .value = "application/json" }};
        // Best-effort: a Herdr push failure must never break the goal turn.
        const resp = self.transport.request(alloc, "POST", url, &headers, body) catch return;
        alloc.free(resp.body);
    }
};

/// Serialize `PaneReportParams` to the exact contract §2 JSON body. Field order
/// and names match the contract; `message` is omitted when null.
fn serialize(alloc: Allocator, p: state.PaneReportParams) ![]u8 {
    const msg_part = if (p.message) |m|
        try std.fmt.allocPrint(alloc, ",\"message\":{f}", .{std.json.fmt(m, .{})})
    else
        "";
    defer if (p.message) |_| alloc.free(msg_part);
    return std.fmt.allocPrint(alloc,
        "{{\"pane_id\":{f},\"source\":{f},\"agent\":{f},\"state\":{f}{s},\"seq\":{d},\"agent_session_id\":{f},\"agent_session_path\":{f}}}",
        .{
            std.json.fmt(p.pane_id, .{}),
            std.json.fmt(p.source, .{}),
            std.json.fmt(p.agent, .{}),
            std.json.fmt(p.state, .{}),
            msg_part,
            p.seq,
            std.json.fmt(p.agent_session_id, .{}),
            std.json.fmt(p.agent_session_path, .{}),
        },
    );
}

/// Default Herdr API base URL (contract §1) when `HERDR_API_URL` is unset.
pub fn defaultApiUrl() []const u8 {
    return "http://localhost:7878";
}

/// Resolve the Herdr API base URL: `HERDR_API_URL` if set, else the default.
/// The returned slice is owned by `alloc` and must be freed by the caller.
pub fn resolveApiUrl(alloc: Allocator) ![]const u8 {
    return resolveApiUrlFrom(alloc, std.process.getEnvVarOwned(alloc, "HERDR_API_URL") catch null);
}

/// Pure variant: `env` non-null wins, otherwise the default. Split out so the
/// set/unset boundary is testable without mutating the process environment.
fn resolveApiUrlFrom(alloc: Allocator, env: ?[]const u8) ![]const u8 {
    if (env) |e| return e;
    return try alloc.dupe(u8, defaultApiUrl());
}

// ---------------------------------------------------------------------------
// Tests (TDD green phase).
// ---------------------------------------------------------------------------

/// Test double that records the last request so the wire format can be asserted
/// without a network.
const CapturingTransport = struct {
    alloc: Allocator,
    method: ?[]const u8 = null,
    url: ?[]const u8 = null,
    headers: ?[]const Header = null,
    body: ?[]const u8 = null,
    status: u16 = 200,
    fail: bool = false,

    pub fn init(alloc: Allocator) CapturingTransport {
        return .{ .alloc = alloc };
    }
    pub fn toTransport(self: *CapturingTransport) Transport {
        return .{ .ctx = self, .vtable = &vtable };
    }
    const vtable = Transport.VTable{ .request = request };

    fn request(ctx: *anyopaque, alloc: Allocator, method: []const u8, url: []const u8, headers: []const Header, body: []const u8) !HttpResponse {
        const self: *CapturingTransport = @ptrCast(@alignCast(ctx));
        if (self.fail) return error.TransportError;
        self.method = try alloc.dupe(u8, method);
        self.url = try alloc.dupe(u8, url);
        self.headers = try alloc.dupe(Header, headers);
        self.body = try alloc.dupe(u8, body);
        return .{ .status = self.status, .body = try alloc.dupe(u8, "") };
    }

    pub fn deinit(self: *CapturingTransport) void {
        if (self.method) |m| self.alloc.free(m);
        if (self.url) |u| self.alloc.free(u);
        if (self.headers) |h| self.alloc.free(h);
        if (self.body) |b| self.alloc.free(b);
    }
};

test "HerdrHttpClient POSTs contract JSON to the report endpoint (U11)" {
    const alloc = std.testing.allocator;
    var cap = CapturingTransport.init(alloc);
    defer cap.deinit();
    var hc = HerdrHttpClient.init(alloc, cap.toTransport(), "http://localhost:7878");
    const params = state.PaneReportParams{
        .pane_id = "pane-1",
        .source = "herdr:ziki",
        .agent = "ziki",
        .state = "working",
        .message = null,
        .seq = 3,
        .agent_session_id = "goal-1",
        .agent_session_path = "/wd/.ziki",
    };
    try hc.doReport(alloc, params);
    try std.testing.expectEqualStrings("POST", cap.method.?);
    try std.testing.expect(std.mem.endsWith(u8, cap.url.?, "/api/v1/pane/report/agent"));
    try std.testing.expectEqual(@as(usize, 1), cap.headers.?.len);
    try std.testing.expectEqualStrings("application/json", cap.headers.?[0].value);
    try std.testing.expect(std.mem.indexOf(u8, cap.body.?, "\"pane_id\":\"pane-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.body.?, "\"source\":\"herdr:ziki\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.body.?, "\"agent\":\"ziki\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.body.?, "\"state\":\"working\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.body.?, "\"seq\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.body.?, "\"agent_session_id\":\"goal-1\"") != null);
}

test "HerdrHttpClient includes message in body when present (U11)" {
    const alloc = std.testing.allocator;
    var cap = CapturingTransport.init(alloc);
    defer cap.deinit();
    var hc = HerdrHttpClient.init(alloc, cap.toTransport(), "http://localhost:7878");
    const params = state.PaneReportParams{
        .pane_id = "pane-1",
        .source = "herdr:ziki",
        .agent = "ziki",
        .state = "blocked",
        .message = "criterion not satisfied",
        .seq = 1,
        .agent_session_id = "goal-1",
        .agent_session_path = "/wd/.ziki",
    };
    try hc.doReport(alloc, params);
    try std.testing.expect(std.mem.indexOf(u8, cap.body.?, "\"message\":\"criterion not satisfied\"") != null);
}

test "resolveApiUrl resolves env when set and default when unset (U12)" {
    const alloc = std.testing.allocator;
    // Boundary via the pure helper (no global env mutation).
    const def = try resolveApiUrlFrom(alloc, null);
    defer alloc.free(def);
    try std.testing.expectEqualStrings("http://localhost:7878", def);
    try std.testing.expectEqualStrings("http://localhost:7878", defaultApiUrl());

    const custom_owned = try alloc.dupe(u8, "http://herdr.local:9999");
    const custom = try resolveApiUrlFrom(alloc, custom_owned);
    defer alloc.free(custom);
    try std.testing.expectEqualStrings("http://herdr.local:9999", custom);

    // The real entry point: when HERDR_API_URL is unset in this process it must
    // resolve to the default. (Skipped if the env var is already set.)
    if (std.process.getEnvVarOwned(alloc, "HERDR_API_URL")) |existing| {
        alloc.free(existing);
    } else |_| {
        const from_env = try resolveApiUrl(alloc);
        defer alloc.free(from_env);
        try std.testing.expectEqualStrings("http://localhost:7878", from_env);
    }
}

test "HerdrHttpClient swallows transport error and does not push (U11 error path)" {
    const alloc = std.testing.allocator;
    var cap = CapturingTransport.init(alloc);
    cap.fail = true;
    defer cap.deinit();
    var hc = HerdrHttpClient.init(alloc, cap.toTransport(), "http://localhost:7878");
    const params = state.PaneReportParams{
        .pane_id = "pane-1",
        .source = "herdr:ziki",
        .agent = "ziki",
        .state = "working",
        .message = null,
        .seq = 3,
        .agent_session_id = "goal-1",
        .agent_session_path = "/wd/.ziki",
    };
    // A transport failure must not propagate: doReport best-effort swallows it.
    try hc.doReport(alloc, params);
    // No request was recorded because the transport failed before capturing.
    try std.testing.expectEqual(@as(?[]const u8, null), cap.method);
}
