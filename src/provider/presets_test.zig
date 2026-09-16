//! Per-provider mock endpoint tests (spec 014, issue #17 Lane B).
//!
//! For each hosted preset a capturing transport records the wire request
//! (URL, auth header form, body shape) and answers with that backend's
//! recorded response fixture — shapes only, no secrets.

const std = @import("std");
const Allocator = std.mem.Allocator;
const provider = @import("provider.zig");
const presets = @import("presets.zig");
const Transport = @import("transport.zig").Transport;
const Header = @import("transport.zig").Header;
const HttpResponse = @import("transport.zig").HttpResponse;

/// Records every request so the wire shape can be asserted; answers with a
/// scripted status/body queue (last entry repeats).
const CapturingTransport = struct {
    alloc: Allocator,
    calls: std.ArrayList(Call),
    responses: []const HttpResponse,
    idx: usize = 0,

    const Call = struct {
        method: []u8,
        url: []u8,
        auth: ?[]u8,
        body: []u8,
    };

    fn init(alloc: Allocator, responses: []const HttpResponse) CapturingTransport {
        return .{ .alloc = alloc, .calls = .{}, .responses = responses };
    }
    fn toTransport(self: *CapturingTransport) Transport {
        return .{ .ctx = self, .vtable = &vtable };
    }
    const vtable = Transport.VTable{ .request = request };

    fn request(ctx: *anyopaque, alloc: Allocator, method: []const u8, url: []const u8, headers: []const Header, body: []const u8) anyerror!HttpResponse {
        const self: *CapturingTransport = @ptrCast(@alignCast(ctx));
        var auth: ?[]u8 = null;
        for (headers) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "authorization")) auth = try alloc.dupe(u8, h.value);
        }
        try self.calls.append(self.alloc, .{
            .method = try alloc.dupe(u8, method),
            .url = try alloc.dupe(u8, url),
            .auth = auth,
            .body = try alloc.dupe(u8, body),
        });
        const r = self.responses[@min(self.idx, self.responses.len - 1)];
        self.idx += 1;
        return .{ .status = r.status, .body = try alloc.dupe(u8, r.body) };
    }

    fn deinit(self: *CapturingTransport) void {
        for (self.calls.items) |c| {
            self.alloc.free(c.method);
            self.alloc.free(c.url);
            if (c.auth) |a| self.alloc.free(a);
            self.alloc.free(c.body);
        }
        self.calls.deinit(self.alloc);
    }
};

// One recorded response fixture per backend (shapes only — no real tokens).
const FIXTURES = [_]struct { name: []const u8, body: []const u8 }{
    .{ .name = "kilo", .body =
    \\{"choices":[{"message":{"role":"assistant","content":"kilo ok"},"finish_reason":"stop"}],
    \\"usage":{"prompt_tokens":11,"completion_tokens":7}}
    },
    .{ .name = "zai", .body =
    \\{"choices":[{"message":{"role":"assistant","content":"zai ok"},"finish_reason":"stop"}],
    \\"usage":{"prompt_tokens":5,"completion_tokens":2}}
    },
    .{ .name = "kimi", .body =
    \\{"choices":[{"message":{"role":"assistant","content":"",
    \\"tool_calls":[{"id":"call_1","type":"function","function":{"name":"read_file","arguments":"{\"path\":\"a\"}"}}]},
    \\"finish_reason":"tool_calls"}]}
    },
    .{ .name = "openai_custom", .body =
    \\{"choices":[{"message":{"role":"assistant","content":"openai ok"},"finish_reason":"stop"}],
    \\"usage":{"prompt_tokens":1,"completion_tokens":1}}
    },
};

test "per-provider request shape and fixture parsing (A1)" {
    const alloc = std.testing.allocator;
    for (FIXTURES) |fx| {
        const preset = presets.findPreset(fx.name).?;
        const responses = [_]HttpResponse{.{ .status = 200, .body = fx.body }};
        var ct = CapturingTransport.init(alloc, &responses);
        defer ct.deinit();

        var impl = try presets.build(alloc, fx.name, "", "", "test-key-redacted", ct.toTransport());
        const p = impl.toProvider();
        const r = try p.complete(alloc, .{
            .messages = &.{.{ .role = .user, .content = "hi" }},
            .tools = &.{.{ .name = "read_file", .description = "read a file", .parameters_json_schema = "{\"type\":\"object\"}" }},
        });

        // Wire shape: preset endpoint + /chat/completions, Bearer auth form.
        const call = ct.calls.items[0];
        try std.testing.expectEqualStrings("POST", call.method);
        const want_url = try std.fmt.allocPrint(alloc, "{s}/chat/completions", .{preset.default_endpoint});
        defer alloc.free(want_url);
        try std.testing.expectEqualStrings(want_url, call.url);
        const want_auth = try std.fmt.allocPrint(alloc, "Bearer {s}", .{"test-key-redacted"});
        defer alloc.free(want_auth);
        try std.testing.expectEqualStrings(want_auth, call.auth.?);
        // Model id placement + raw tool schema encoding.
        const want_model = try std.fmt.allocPrint(alloc, "\"model\":\"{s}\"", .{preset.default_model});
        defer alloc.free(want_model);
        try std.testing.expect(std.mem.indexOf(u8, call.body, want_model) != null);
        try std.testing.expect(std.mem.indexOf(u8, call.body, "\"parameters\":{\"type\":\"object\"}") != null);
        try std.testing.expect(std.mem.indexOf(u8, call.body, "\"tool_choice\":\"auto\"") != null);

        // Fixture parses to the same response fields (assert BEFORE freeing).
        defer alloc.free(r.message.content);
        if (std.mem.eql(u8, fx.name, "kimi")) {
            try std.testing.expect(r.finish_reason == .tool_calls);
            try std.testing.expectEqualStrings("read_file", r.message.tool_calls.?[0].name);
        } else {
            try std.testing.expect(r.finish_reason == .stop);
            try std.testing.expect(r.usage != null);
            try std.testing.expect(r.usage.?.total() > 0);
        }
        if (r.message.tool_calls) |tcs| {
            for (tcs) |tc| {
                alloc.free(tc.id);
                alloc.free(tc.name);
                alloc.free(tc.arguments_json);
            }
            alloc.free(tcs);
        }
    }
}
