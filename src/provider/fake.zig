const std = @import("std");
const Allocator = std.mem.Allocator;
const provider = @import("provider.zig");

/// Deterministic, scripted provider for tests and offline e2e. Returns the
/// scripted ChatResponse sequence in order, holding on the last when exhausted.
pub const FakeProvider = struct {
    responses: []const provider.ChatResponse,
    idx: usize = 0,

    pub fn init(responses: []const provider.ChatResponse) FakeProvider {
        return .{ .responses = responses };
    }
    pub fn toProvider(self: *FakeProvider) provider.Provider {
        return .{ .ctx = self, .vtable = &vtable };
    }
    const vtable = provider.Provider.VTable{ .complete = complete, .name = name };

    fn name(_: *anyopaque) []const u8 {
        return "fake";
    }
    fn complete(ctx: *anyopaque, alloc: Allocator, _: provider.CompletionRequest) !provider.ChatResponse {
        const self: *FakeProvider = @ptrCast(@alignCast(ctx));
        const r = self.responses[self.idx];
        if (self.idx + 1 < self.responses.len) self.idx += 1;
        return try clone(alloc, r);
    }
};

fn clone(alloc: Allocator, r: provider.ChatResponse) !provider.ChatResponse {
    var tcs: ?[]provider.ToolCall = null;
    if (r.message.tool_calls) |src| {
        const owned = try alloc.alloc(provider.ToolCall, src.len);
        for (src, 0..) |tc, i| {
            owned[i] = .{
                .id = try alloc.dupe(u8, tc.id),
                .name = try alloc.dupe(u8, tc.name),
                .arguments_json = try alloc.dupe(u8, tc.arguments_json),
            };
        }
        tcs = owned;
    }
    return provider.ChatResponse{
        .message = .{
            .role = r.message.role,
            .content = try alloc.dupe(u8, r.message.content),
            .tool_calls = tcs,
            .tool_call_id = if (r.message.tool_call_id) |x| try alloc.dupe(u8, x) else null,
        },
        .finish_reason = r.finish_reason,
        .usage = r.usage,
    };
}

test "FakeProvider steps through script and clones" {
    const rs = [_]provider.ChatResponse{
        .{ .message = .{ .role = .assistant, .content = "a" } },
        .{ .message = .{ .role = .assistant, .content = "b" } },
    };
    var fp = FakeProvider.init(&rs);
    const p = fp.toProvider();
    const r1 = try p.complete(std.testing.allocator, .{ .messages = &[0]provider.ChatMessage{}, .tools = &[0]provider.ToolSpec{} });
    const r2 = try p.complete(std.testing.allocator, .{ .messages = &[0]provider.ChatMessage{}, .tools = &[0]provider.ToolSpec{} });
    defer std.testing.allocator.free(r1.message.content);
    defer std.testing.allocator.free(r2.message.content);
    try std.testing.expectEqualStrings("a", r1.message.content);
    try std.testing.expectEqualStrings("b", r2.message.content);
}

/// Provider that fails the first `fails` calls, then returns `ok_response`.
/// Used to exercise retry logic without real network flakiness.
pub const FlakyProvider = struct {
    fails: usize,
    ok_response: provider.ChatResponse,
    calls: usize = 0,

    pub fn init(fails: usize, ok_response: provider.ChatResponse) FlakyProvider {
        return .{ .fails = fails, .ok_response = ok_response };
    }
    pub fn toProvider(self: *FlakyProvider) provider.Provider {
        return .{ .ctx = self, .vtable = &vtable };
    }
    const vtable = provider.Provider.VTable{ .complete = complete, .name = name };

    fn name(_: *anyopaque) []const u8 {
        return "flaky";
    }
    fn complete(ctx: *anyopaque, alloc: Allocator, _: provider.CompletionRequest) !provider.ChatResponse {
        const self: *FlakyProvider = @ptrCast(@alignCast(ctx));
        const n = self.calls;
        self.calls += 1;
        if (n < self.fails) return error.ProviderError;
        return try clone(alloc, self.ok_response);
    }
};

test "FlakyProvider fails first N then succeeds" {
    const ok = provider.ChatResponse{ .message = .{ .role = .assistant, .content = "ok" } };
    var fp = FlakyProvider.init(2, ok);
    const p = fp.toProvider();
    const req: provider.CompletionRequest = .{ .messages = &[0]provider.ChatMessage{}, .tools = &[0]provider.ToolSpec{} };
    try std.testing.expectError(error.ProviderError, p.complete(std.testing.allocator, req));
    try std.testing.expectError(error.ProviderError, p.complete(std.testing.allocator, req));
    const r = try p.complete(std.testing.allocator, req);
    defer std.testing.allocator.free(r.message.content);
    try std.testing.expectEqualStrings("ok", r.message.content);
}

/// Provider that records the message list of every request (role/content
/// lines) so tests can assert what the executor actually sent (spec 013 B6).
pub const RecordingProvider = struct {
    alloc: Allocator,
    response: provider.ChatResponse,
    calls: usize = 0,
    log: std.ArrayList(u8),

    pub fn init(alloc: Allocator, response: provider.ChatResponse) RecordingProvider {
        return .{ .alloc = alloc, .response = response, .log = std.ArrayList(u8).initCapacity(alloc, 0) catch unreachable };
    }
    pub fn deinit(self: *RecordingProvider) void {
        self.log.deinit(self.alloc);
    }
    pub fn toProvider(self: *RecordingProvider) provider.Provider {
        return .{ .ctx = self, .vtable = &vtable };
    }
    const vtable = provider.Provider.VTable{ .complete = complete, .name = name };

    fn name(_: *anyopaque) []const u8 {
        return "recording";
    }
    fn complete(ctx: *anyopaque, alloc: Allocator, req: provider.CompletionRequest) !provider.ChatResponse {
        const self: *RecordingProvider = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        for (req.messages) |m| {
            try self.log.appendSlice(self.alloc, m.role.jsonString());
            try self.log.appendSlice(self.alloc, ":");
            try self.log.appendSlice(self.alloc, m.content);
            try self.log.appendSlice(self.alloc, "\n");
        }
        try self.log.appendSlice(self.alloc, "---\n");
        return try clone(alloc, self.response);
    }
};

test "RecordingProvider captures request contents" {
    const rs = provider.ChatResponse{ .message = .{ .role = .assistant, .content = "ok" } };
    var rp = RecordingProvider.init(std.testing.allocator, rs);
    defer rp.deinit();
    const p = rp.toProvider();
    const msgs = [_]provider.ChatMessage{.{ .role = .user, .content = "seeded turn" }};
    const r = try p.complete(std.testing.allocator, .{ .messages = &msgs, .tools = &[0]provider.ToolSpec{} });
    defer std.testing.allocator.free(r.message.content);
    try std.testing.expect(std.mem.indexOf(u8, rp.log.items, "user:seeded turn\n") != null);
    try std.testing.expectEqual(@as(usize, 1), rp.calls);
}
