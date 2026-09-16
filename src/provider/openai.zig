const std = @import("std");
const Allocator = std.mem.Allocator;
const provider = @import("provider.zig");
const Transport = @import("transport.zig").Transport;
const Header = @import("transport.zig").Header;
const HttpResponse = @import("transport.zig").HttpResponse;

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
    /// Comma-joined model ids from the gateway's models list, captured when a
    /// model-id rejection triggered the error-path probe (spec 014 US4).
    models_hint: ?[]u8 = null,

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
    /// Frees the provider-owned `models_hint` slice captured by the error-path
    /// probe (spec 014 US4). Call once when the provider is torn down.
    pub fn deinit(self: *OpenAIProvider, alloc: Allocator) void {
        if (self.models_hint) |h| alloc.free(h);
        self.models_hint = null;
    }
    pub fn toProvider(self: *OpenAIProvider) provider.Provider {
        return .{ .ctx = self, .vtable = &vtable };
    }
    const vtable = provider.Provider.VTable{ .complete = complete, .name = name, .error_hint = errorHint };

    fn errorHint(ctx: *anyopaque) ?[]const u8 {
        const self: *OpenAIProvider = @ptrCast(@alignCast(ctx));
        return self.models_hint;
    }

    /// Best-effort models-list probe for the error path (spec 014 US4):
    /// GET {endpoint}/models, join up to 8 ids. Any failure leaves the hint
    /// unset — the caller's message must be actionable without it.
    fn probeModels(self: *OpenAIProvider) void {
        const alloc = self.alloc;
        const url = std.fmt.allocPrint(alloc, "{s}/models", .{self.endpoint}) catch return;
        defer alloc.free(url);
        var headers: [1]Header = undefined;
        var n: usize = 0;
        var auth: []const u8 = "";
        if (self.api_key.len > 0) {
            auth = std.fmt.allocPrint(alloc, "Bearer {s}", .{self.api_key}) catch return;
        }
        // The defer must live at function scope: inside the `if` above it would
        // free the string before `request` runs below.
        defer if (auth.len > 0) alloc.free(auth);
        if (auth.len > 0) {
            headers[n] = .{ .name = "authorization", .value = auth };
            n += 1;
        }
        const resp = self.transport.request(alloc, "GET", url, headers[0..n], "") catch return;
        defer alloc.free(resp.body);
        // Only a 2xx body carries a models list — never parse an error body.
        if (resp.status < 200 or resp.status >= 300) return;
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, resp.body, .{}) catch return;
        defer parsed.deinit();
        if (parsed.value != .object) return;
        const data = parsed.value.object.get("data") orelse return;
        if (data != .array) return;
        var buf = std.ArrayList(u8){};
        var count: usize = 0;
        for (data.array.items) |item| {
            if (item != .object) continue;
            const idv = item.object.get("id") orelse continue;
            if (idv != .string) continue;
            if (count > 0) buf.appendSlice(alloc, ", ") catch break;
            buf.appendSlice(alloc, idv.string) catch break;
            count += 1;
            if (count >= 8) break;
        }
        if (count == 0) {
            buf.deinit(alloc);
            return;
        }
        if (self.models_hint) |old| alloc.free(old);
        if (buf.toOwnedSlice(alloc)) |owned| {
            self.models_hint = owned;
        } else |_| {
            buf.deinit(alloc);
        }
    }

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
        var auth: []const u8 = "";
        if (self.api_key.len > 0) {
            auth = try std.fmt.allocPrint(alloc, "Bearer {s}", .{self.api_key});
        }
        defer if (auth.len > 0) alloc.free(auth);
        if (auth.len > 0) {
            headers[n] = .{ .name = "authorization", .value = auth };
            n += 1;
        }

        const url = try std.fmt.allocPrint(alloc, "{s}/chat/completions", .{self.endpoint});
        defer alloc.free(url);

        const resp = try self.transport.request(alloc, "POST", url, headers[0..n], body);
        defer alloc.free(resp.body);

        if (resp.status < 200 or resp.status >= 300) {
            // Spec 014 US3/US4: distinct, non-transient error kinds. Message
            // strings never embed key material or response bodies.
            switch (resp.status) {
                401 => return error.Unauthorized,
                403 => return error.Forbidden,
                400, 404 => {
                    self.probeModels();
                    return error.ModelNotFound;
                },
                else => return error.ProviderError,
            }
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

    // Token usage (spec 013): top-level `usage` object when the backend
    // reports it; omitted/absent usage stays null so the executor estimates.
    var usage: ?provider.TokenUsage = null;
    if (root.value.object.get("usage")) |uv| {
        if (uv == .object) {
            const pt: u64 = if (uv.object.get("prompt_tokens")) |v|
                (if (v == .integer and v.integer >= 0) @intCast(v.integer) else 0)
            else
                0;
            const ct: u64 = if (uv.object.get("completion_tokens")) |v|
                (if (v == .integer and v.integer >= 0) @intCast(v.integer) else 0)
            else
                0;
            usage = .{ .prompt_tokens = pt, .completion_tokens = ct };
        }
    }

    return provider.ChatResponse{
        .message = .{ .role = .assistant, .content = content, .tool_calls = tool_calls },
        .finish_reason = finish_reason,
        .usage = usage,
    };
}

test "parseResponse maps token usage when present (B19)" {
    const body =
        \\{"choices":[{"message":{"role":"assistant","content":"ok"}}],
        \\"usage":{"prompt_tokens":120,"completion_tokens":34}}
    ;
    const r = try parseResponse(std.testing.allocator, body);
    defer std.testing.allocator.free(r.message.content);
    try std.testing.expect(r.usage != null);
    try std.testing.expectEqual(@as(u64, 120), r.usage.?.prompt_tokens);
    try std.testing.expectEqual(@as(u64, 34), r.usage.?.completion_tokens);
    try std.testing.expectEqual(@as(u64, 154), r.usage.?.total());
}

test "parseResponse leaves usage null when the backend omits it (B19)" {
    const body =
        \\{"choices":[{"message":{"role":"assistant","content":"hi"}}]}
    ;
    const r = try parseResponse(std.testing.allocator, body);
    defer std.testing.allocator.free(r.message.content);
    try std.testing.expect(r.usage == null);
}

test "ChatResponse.usage defaults to null (B19)" {
    const r = provider.ChatResponse{ .message = .{ .role = .assistant, .content = "" } };
    try std.testing.expect(r.usage == null);
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

// ---------------------------------------------------------------------------
// Tests: credential + model-id error paths (spec 014 US3/US4).
// ---------------------------------------------------------------------------

const CapResp = struct { status: u16, body: []const u8 };

const CapTransport = struct {
    alloc: Allocator,
    script: []const CapResp,
    idx: usize = 0,
    methods: std.ArrayList([]u8),
    urls: std.ArrayList([]u8),
    auths: std.ArrayList([]u8),

    fn init(alloc: Allocator, script: []const CapResp) CapTransport {
        return .{ .alloc = alloc, .script = script, .methods = .{}, .urls = .{}, .auths = .{} };
    }
    fn toTransport(self: *CapTransport) Transport {
        return .{ .ctx = self, .vtable = &vtable };
    }
    const vtable = Transport.VTable{ .request = request };

    fn request(ctx: *anyopaque, alloc: Allocator, method: []const u8, url: []const u8, headers: []const Header, body: []const u8) anyerror!HttpResponse {
        _ = body;
        const self: *CapTransport = @ptrCast(@alignCast(ctx));
        try self.methods.append(self.alloc, try alloc.dupe(u8, method));
        try self.urls.append(self.alloc, try alloc.dupe(u8, url));
        var auth: []const u8 = "";
        for (headers) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "authorization")) auth = h.value;
        }
        try self.auths.append(self.alloc, try alloc.dupe(u8, auth));
        const s = self.script[@min(self.idx, self.script.len - 1)];
        self.idx += 1;
        return .{ .status = s.status, .body = try alloc.dupe(u8, s.body) };
    }
    fn lastUrl(self: *CapTransport) []const u8 {
        return self.urls.items[self.urls.items.len - 1];
    }
    fn deinit(self: *CapTransport) void {
        for (self.methods.items) |m| self.alloc.free(m);
        self.methods.deinit(self.alloc);
        for (self.urls.items) |u| self.alloc.free(u);
        self.urls.deinit(self.alloc);
        for (self.auths.items) |a| self.alloc.free(a);
        self.auths.deinit(self.alloc);
    }
};

test "complete maps 401/403 to credential errors (A3)" {
    const alloc = std.testing.allocator;
    for ([_]CapResp{ .{ .status = 401, .body = "{\"error\":{\"message\":\"bad key\"}}" }, .{ .status = 403, .body = "{\"error\":{\"message\":\"quota\"}}" } }) |script| {
        var ct = CapTransport.init(alloc, &.{script});
        defer ct.deinit();
        var p = OpenAIProvider.init(alloc, "kilo", "https://gw.test/api", "m-1", "sk-secret-do-not-leak", ct.toTransport());
        const pr = p.toProvider();
        const req: provider.CompletionRequest = .{ .messages = &.{.{ .role = .user, .content = "hi" }}, .tools = &.{} };
        const want: anyerror = if (script.status == 401) error.Unauthorized else error.Forbidden;
        try std.testing.expectError(want, pr.complete(alloc, req));
        // Exactly one wire attempt (no provider-side retry burn).
        try std.testing.expectEqual(@as(usize, 1), ct.urls.items.len);
    }
}

test "complete maps 404 to ModelNotFound and probes the models list (A4)" {
    const alloc = std.testing.allocator;
    const script = [_]CapResp{
        .{ .status = 404, .body = "{\"error\":{\"message\":\"model nex-agi/nope not found\"}}" },
        .{ .status = 200, .body = "{\"data\":[{\"id\":\"m-a\"},{\"id\":\"m-b\"}]}" },
    };
    var ct = CapTransport.init(alloc, &script);
    defer ct.deinit();
    var p = OpenAIProvider.init(alloc, "kilo", "https://gw.test/api", "nex-agi/nope", "k", ct.toTransport());
    defer p.deinit(alloc); // provider-owned models_hint captured by the probe
    const pr = p.toProvider();
    const req: provider.CompletionRequest = .{ .messages = &.{.{ .role = .user, .content = "hi" }}, .tools = &.{} };
    try std.testing.expectError(error.ModelNotFound, pr.complete(alloc, req));
    // The error path probed GET {endpoint}/models.
    try std.testing.expectEqualStrings("GET", ct.methods.items[1]);
    try std.testing.expectEqualStrings("https://gw.test/api/models", ct.lastUrl());
    // Both wire calls carry `Bearer <key>` — the probe once sent the raw key.
    try std.testing.expectEqualStrings("Bearer k", ct.auths.items[0]);
    try std.testing.expectEqualStrings("Bearer k", ct.auths.items[1]);
    // The hint is reachable on the error path and lists the gateway's ids.
    try std.testing.expectEqualStrings("m-a, m-b", pr.errorHint().?);
}
