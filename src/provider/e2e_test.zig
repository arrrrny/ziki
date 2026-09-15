const std = @import("std");
const provider = @import("provider.zig");
const fake = @import("fake.zig");
const presets = @import("presets.zig");
const transport = @import("transport.zig");
const openai = @import("openai.zig");

/// End-to-end provider tests. Offline tests use FakeProvider/FakeTransport so
/// the suite is deterministic. A single gated live test pings the configured
/// provider when ZIKI_API_KEY is set; it skips silently otherwise.

const CompletionRequest = provider.CompletionRequest;
const ChatMessage = provider.ChatMessage;
const ChatResponse = provider.ChatResponse;
const ToolSpec = provider.ToolSpec;
const ToolCall = provider.ToolCall;

fn msg(role: provider.Role, content: []const u8) ChatMessage {
    return .{ .role = role, .content = content };
}

test "e2e: FakeProvider drives a scripted completion turn" {
    const rs = [_]ChatResponse{
        .{ .message = msg(.assistant, "hello"), .finish_reason = .stop },
    };
    var fp = fake.FakeProvider.init(&rs);
    const p = fp.toProvider();
    const req: CompletionRequest = .{
        .messages = &[_]ChatMessage{ msg(.user, "hi") },
        .tools = &[_]ToolSpec{},
    };
    const r = try p.complete(std.testing.allocator, req);
    defer std.testing.allocator.free(r.message.content);
    try std.testing.expectEqualStrings("hello", r.message.content);
    try std.testing.expectEqual(provider.FinishReason.stop, r.finish_reason);
}

test "e2e: FakeProvider emits tool_calls and preserves call ids" {
    const rs = [_]ChatResponse{
        .{
            .message = .{
                .role = .assistant,
                .content = "",
                .tool_calls = &[_]ToolCall{
                    .{ .id = "call_1", .name = "read", .arguments_json = "{\"path\":\"/tmp/x\"}" },
                },
            },
            .finish_reason = .tool_calls,
        },
    };
    var fp = fake.FakeProvider.init(&rs);
    const p = fp.toProvider();
    const req: CompletionRequest = .{
        .messages = &[_]ChatMessage{ msg(.user, "read the file") },
        .tools = &[_]ToolSpec{},
    };
    const r = try p.complete(std.testing.allocator, req);
    defer std.testing.allocator.free(r.message.content);
    const tcs = r.message.tool_calls.?;
    defer std.testing.allocator.free(tcs);
    defer std.testing.allocator.free(tcs[0].arguments_json);
    defer std.testing.allocator.free(tcs[0].name);
    defer std.testing.allocator.free(tcs[0].id);
    try std.testing.expectEqual(provider.FinishReason.tool_calls, r.finish_reason);
    try std.testing.expectEqualStrings("call_1", r.message.tool_calls.?[0].id);
    try std.testing.expectEqualStrings("read", r.message.tool_calls.?[0].name);
}

test "e2e: presets.build returns a valid provider for every preset" {
    const names = [_][]const u8{
        "opencode", "kilo", "zai", "kimi", "openai_custom", "cliproxy",
    };
    var ft = transport.FakeTransport.init(200, "{}");
    const t = ft.toTransport();
    var built: usize = 0;
    for (names) |name| {
        const cfg = try presets.build(std.testing.allocator, name, "", "", "", t);
        try std.testing.expect(cfg.endpoint.len > 0);
        try std.testing.expect(cfg.model.len > 0);
        built += 1;
    }
    try std.testing.expectEqual(@as(usize, 6), built);
}

test "e2e: presets.build rejects unknown provider" {
    var ft = transport.FakeTransport.init(200, "{}");
    const t = ft.toTransport();
    try std.testing.expectError(error.UnknownProvider, presets.build(std.testing.allocator, "nope", "", "", "", t));
}

test "e2e: FlakyProvider recovers after transient failures" {
    const ok = ChatResponse{ .message = msg(.assistant, "recovered") };
    var fp = fake.FlakyProvider.init(3, ok);
    const p = fp.toProvider();
    const req: CompletionRequest = .{
        .messages = &[_]ChatMessage{ msg(.user, "x") },
        .tools = &[_]ToolSpec{},
    };
    try std.testing.expectError(error.ProviderError, p.complete(std.testing.allocator, req));
    try std.testing.expectError(error.ProviderError, p.complete(std.testing.allocator, req));
    try std.testing.expectError(error.ProviderError, p.complete(std.testing.allocator, req));
    const r = try p.complete(std.testing.allocator, req);
    defer std.testing.allocator.free(r.message.content);
    try std.testing.expectEqualStrings("recovered", r.message.content);
}

test "e2e: OpenAIProvider round-trips a request through FakeTransport" {
    const body = "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"pong\"},\"finish_reason\":\"stop\"}]}";
    var ft = transport.FakeTransport.init(200, body);
    const t = ft.toTransport();
    var p = openai.OpenAIProvider.init(
        std.testing.allocator,
        "openai",
        "https://api.openai.com/v1",
        "gpt-test",
        "sk-test",
        t,
    );
    const pr = p.toProvider();
    const req: CompletionRequest = .{
        .messages = &[_]ChatMessage{ msg(.user, "ping") },
        .tools = &[_]ToolSpec{},
        .budget_tokens = 8,
    };
    const r = try pr.complete(std.testing.allocator, req);
    defer std.testing.allocator.free(r.message.content);
    try std.testing.expectEqualStrings("pong", r.message.content);
    try std.testing.expectEqual(provider.FinishReason.stop, r.finish_reason);
}

// Live connectivity test. Runs only when ZIKI_API_KEY is set, so CI without
// secrets stays green. Prints nothing about the key itself.
test "e2e: live provider responds to a trivial completion (gated)" {
    const api_key = std.posix.getenv("ZIKI_API_KEY") orelse return error.SkipZigTest;
    const endpoint = std.posix.getenv("ZIKI_ENDPOINT") orelse "https://api.kilo.ai/v1";
    const model = std.posix.getenv("ZIKI_MODEL") orelse "kilo-1";
    var real_t = try transport.HttpTransport.init(std.testing.allocator, null);
    defer real_t.deinit();
    const t = real_t.toTransport();
    var p = openai.OpenAIProvider.init(
        std.testing.allocator,
        "kilo",
        endpoint,
        model,
        api_key,
        t,
    );
    const pr = p.toProvider();
    const req: CompletionRequest = .{
        .messages = &[_]ChatMessage{
            msg(.system, "You reply with exactly one word."),
            msg(.user, "Say hello"),
        },
        .tools = &[_]ToolSpec{},
        .budget_tokens = 8,
    };
    const r = try pr.complete(std.testing.allocator, req);
    defer std.testing.allocator.free(r.message.content);
    try std.testing.expect(r.message.content.len > 0);
}