const std = @import("std");
const Allocator = std.mem.Allocator;
const provider = @import("provider.zig");
const Transport = @import("transport.zig").Transport;
const Header = @import("transport.zig").Header;

/// OpenAI-compatible Chat Completions client. This is the single reference
/// provider (spec 004); the five required providers are config presets over it
/// (no per-provider branching — OCP).
pub const OpenAIProvider = struct {
    provider_name: []const u8,
    endpoint: []const u8,
    model: []const u8,
    api_key: []const u8,
    transport: Transport,
    alloc: Allocator,

    pub fn init(alloc: Allocator, provider_name: []const u8, endpoint: []const u8, model: []const u8, api_key: []const u8, transport: Transport) OpenAIProvider {
        return .{
            .provider_name = provider_name,
            .endpoint = endpoint,
            .model = model,
            .api_key = api_key,
            .transport = transport,
            .alloc = alloc,
        };
    }
    pub fn toProvider(self: *OpenAIProvider) provider.Provider {
        return .{ .ctx = self, .vtable = &vtable };
    }
    const vtable = provider.Provider.VTable{ .complete = complete, .name = name };

    fn name(ctx: *anyopaque) []const u8 {
        const self: *OpenAIProvider = @ptrCast(@alignCast(ctx));
        return self.provider_name;
    }

    fn complete(ctx: *anyopaque, alloc: Allocator, req: provider.CompletionRequest) !provider.ChatResponse {
        const self: *OpenAIProvider = @ptrCast(@alignCast(ctx));

        const body = try buildRequestBody(alloc, self.model, req.messages, req.tools);
        defer alloc.free(body);

        var headers: [2]Header = undefined;
        var n: usize = 0;
        headers[n] = .{ .name = "content-type", .value = "application/json" };
        n += 1;
        if (self.api_key.len > 0) {
            const auth = try std.fmt.allocPrint(alloc, "Bearer {s}", .{self.api_key});
            headers[n] = .{ .name = "authorization", .value = auth };
            n += 1;
        }

        const url = try std.fmt.allocPrint(alloc, "{s}/chat/completions", .{self.endpoint});
        defer alloc.free(url);

        const resp = try self.transport.request(alloc, "POST", url, headers[0..n], body);
        defer alloc.free(resp.body);

        if (resp.status < 200 or resp.status >= 300) {
            return error.ProviderError;
        }

        return try parseResponse(alloc, resp.body);
    }
};

fn buildRequestBody(alloc: Allocator, model: []const u8, messages: []const provider.ChatMessage, tools: []const provider.ToolSpec) ![]u8 {
    var buf = try std.ArrayList(u8).initCapacity(alloc, 0);
    var w = buf.writer(alloc);
    try w.print("{{\"model\":{f},\"messages\":[", .{std.json.fmt(model, .{})});
    for (messages, 0..) |m, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("{{\"role\":{f},\"content\":{f}", .{ std.json.fmt(m.role.jsonString(), .{}), std.json.fmt(m.content, .{}) });
        if (m.tool_calls) |tcs| {
            try w.writeAll(",\"tool_calls\":[");
            for (tcs, 0..) |tc, j| {
                if (j > 0) try w.writeByte(',');
                try w.print("{{\"id\":{f},\"type\":\"function\",\"function\":{{\"name\":{f},\"arguments\":{f}}}}}", .{
                    std.json.fmt(tc.id, .{}),
                    std.json.fmt(tc.name, .{}),
                    std.json.fmt(tc.arguments_json, .{}),
                });
            }
            try w.writeByte(']');
        }
        if (m.tool_call_id) |id| {
            try w.print(",\"tool_call_id\":{f}", .{std.json.fmt(id, .{})});
        }
        try w.writeByte('}');
    }
    try w.writeAll("],\"tools\":[");
    for (tools, 0..) |t, i| {
        if (i > 0) try w.writeByte(',');
        // parameters_json_schema is already a JSON object string; embed raw.
        try w.print("{{\"type\":\"function\",\"function\":{{\"name\":{f},\"description\":{f},\"parameters\":{s}}}}}", .{
            std.json.fmt(t.name, .{}),
            std.json.fmt(t.description, .{}),
            t.parameters_json_schema,
        });
    }
    try w.writeAll("],\"tool_choice\":\"auto\"}");
    return buf.toOwnedSlice(alloc);
}

fn parseResponse(alloc: Allocator, body: []const u8) !provider.ChatResponse {
    // Dynamic parsing: provider schemas vary (e.g. cliproxy omits the
    // `tool_calls` and `finish_reason` fields on no-tool-call turns), so we
    // navigate by key and treat any missing field as its zero value.
    const root = try std.json.parseFromSlice(std.json.Value, alloc, body, .{ .ignore_unknown_fields = true });
    defer root.deinit();

    const choices = root.value.object.get("choices") orelse return error.NoChoices;
    if (choices != .array or choices.array.items.len == 0) return error.NoChoices;
    const first = choices.array.items[0];
    if (first != .object) return error.NoChoices;
    const msg = first.object.get("message") orelse return error.NoChoices;
    if (msg != .object) return error.NoChoices;

    const content_raw = if (msg.object.get("content")) |cv| (if (cv == .string) cv.string else "") else "";
    const content = try alloc.dupe(u8, content_raw);

    var tool_calls: ?[]provider.ToolCall = null;
    if (msg.object.get("tool_calls")) |tcs_v| {
        if (tcs_v == .array) {
            const arr = tcs_v.array.items;
            const owned = try alloc.alloc(provider.ToolCall, arr.len);
            for (arr, 0..) |tc, i| {
                const fn_v = if (tc.object.get("function")) |f| f else return error.ProviderError;
                if (fn_v != .object) return error.ProviderError;
                const id = if (tc.object.get("id")) |v| (if (v == .string) v.string else "") else "";
                const name = if (fn_v.object.get("name")) |v| (if (v == .string) v.string else "") else "";
                const args = if (fn_v.object.get("arguments")) |v| (if (v == .string) v.string else "") else "";
                owned[i] = .{
                    .id = try alloc.dupe(u8, id),
                    .name = try alloc.dupe(u8, name),
                    .arguments_json = try alloc.dupe(u8, args),
                };
            }
            tool_calls = owned;
        }
    }

    var finish_reason: provider.FinishReason = .stop;
    if (first.object.get("finish_reason")) |fr_v| {
        if (fr_v == .string) finish_reason = provider.FinishReason.fromJson(fr_v.string);
    }

    return provider.ChatResponse{
        .message = .{ .role = .assistant, .content = content, .tool_calls = tool_calls },
        .finish_reason = finish_reason,
    };
}

test "parseResponse maps tool_calls" {
    const body =
        \\{"choices":[{"message":{"role":"assistant","content":null,
        \\"tool_calls":[{"id":"c1","function":{"name":"write_file","arguments":"{\"path\":\"a.txt\",\"data\":\"hi\"}"}}]},
        \\"finish_reason":"tool_calls"}]}
    ;
    const r = try parseResponse(std.testing.allocator, body);
    defer std.testing.allocator.free(r.message.content);
    if (r.message.tool_calls) |tcs| {
        defer {
            for (tcs) |tc| {
                std.testing.allocator.free(tc.id);
                std.testing.allocator.free(tc.name);
                std.testing.allocator.free(tc.arguments_json);
            }
            std.testing.allocator.free(tcs);
        }
        try std.testing.expectEqual(@as(usize, 1), tcs.len);
        try std.testing.expectEqualStrings("write_file", tcs[0].name);
        try std.testing.expect(r.finish_reason == .tool_calls);
    } else unreachable;
}

test "parseResponse tolerates missing tool_calls/finish_reason" {
    // Mirror cliproxy's no-tool-call turn: no `tool_calls`, no `finish_reason`,
    // plus extra unknown keys (`refusal`, `reasoning`, `reasoning_details`).
    const body =
        \\{"choices":[{"message":{"role":"assistant",
        \\"content":"Hello, I can help with that.","refusal":null,
        \\"reasoning":"","reasoning_details":[]}}]}
    ;
    const r = try parseResponse(std.testing.allocator, body);
    defer std.testing.allocator.free(r.message.content);
    try std.testing.expectEqualStrings("Hello, I can help with that.", r.message.content);
    try std.testing.expect(r.message.tool_calls == null);
    try std.testing.expect(r.finish_reason == .stop);
}

test "buildRequestBody embeds raw schema" {
    const tools = [_]provider.ToolSpec{.{ .name = "t", .description = "d", .parameters_json_schema = "{\"type\":\"object\"}" }};
    const tcs = [_]provider.ToolCall{.{ .id = "c1", .name = "t", .arguments_json = "{\"x\":1}" }};
    const msgs = [_]provider.ChatMessage{
        .{ .role = .user, .content = "hi" },
        // An assistant message with tool_calls — the regression case for a
        // closing brace emitted before `tool_calls` (multi-turn requests).
        .{ .role = .assistant, .content = "", .tool_calls = &tcs },
    };
    const body = try buildRequestBody(std.testing.allocator, "gpt", &msgs, &tools);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"parameters\":{\"type\":\"object\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"model\":\"gpt\"") != null);

    // The request must be valid JSON (catches the multi-turn closing-brace bug).
    const Parsed = struct {
        model: []const u8,
        messages: []const struct { role: []const u8, content: []const u8 },
    };
    var parsed = try std.json.parseFromSlice(Parsed, std.testing.allocator, body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqualStrings("gpt", parsed.value.model);
    try std.testing.expectEqual(@as(usize, 2), parsed.value.messages.len);
    try std.testing.expectEqualStrings("user", parsed.value.messages[0].role);
    try std.testing.expectEqualStrings("assistant", parsed.value.messages[1].role);
    // tool_calls must be present and nested inside the assistant message object.
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tool_calls\":[{\"id\":\"c1\"") != null);
}
