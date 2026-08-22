const std = @import("std");
const Allocator = std.mem.Allocator;

/// Author role for a chat message.
pub const Role = enum {
    system,
    user,
    assistant,
    tool,

    pub fn jsonString(self: Role) []const u8 {
        return switch (self) {
            .system => "system",
            .user => "user",
            .assistant => "assistant",
            .tool => "tool",
        };
    }
    pub fn fromJson(s: []const u8) !Role {
        if (std.mem.eql(u8, s, "system")) return .system;
        if (std.mem.eql(u8, s, "user")) return .user;
        if (std.mem.eql(u8, s, "assistant")) return .assistant;
        if (std.mem.eql(u8, s, "tool")) return .tool;
        return error.InvalidRole;
    }
};

/// A function the model decided to call.
pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    arguments_json: []const u8,
};

/// One message in the conversation.
pub const ChatMessage = struct {
    role: Role,
    content: []const u8 = "",
    tool_calls: ?[]const ToolCall = null,
    tool_call_id: ?[]const u8 = null,
};

/// Why the model stopped generating.
pub const FinishReason = enum {
    stop,
    tool_calls,
    length,

    pub fn fromJson(s: []const u8) FinishReason {
        if (std.mem.eql(u8, s, "tool_calls")) return .tool_calls;
        if (std.mem.eql(u8, s, "length")) return .length;
        return .stop;
    }
};

/// The model's reply for one turn.
pub const ChatResponse = struct {
    message: ChatMessage,
    finish_reason: FinishReason = .stop,
};

/// A tool's schema exposed to the model.
pub const ToolSpec = struct {
    name: []const u8,
    description: []const u8,
    parameters_json_schema: []const u8,
};

/// Input to a provider completion call.
pub const CompletionRequest = struct {
    messages: []const ChatMessage,
    tools: []const ToolSpec,
    budget_tokens: ?u64 = null,
};

/// Model backend boundary (DI). All five providers implement this one
/// interface so the executor is provider-agnostic (LSP, DIP).
pub const Provider = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        complete: *const fn (ctx: *anyopaque, alloc: Allocator, req: CompletionRequest) anyerror!ChatResponse,
        name: *const fn (ctx: *anyopaque) []const u8,
    };

    pub fn complete(self: Provider, alloc: Allocator, req: CompletionRequest) !ChatResponse {
        return self.vtable.complete(self.ctx, alloc, req);
    }
    pub fn name(self: Provider) []const u8 {
        return self.vtable.name(self.ctx);
    }
};

test "Role/FinishReason json mapping" {
    try std.testing.expectEqualStrings("assistant", Role.assistant.jsonString());
    try std.testing.expect(FinishReason.fromJson("tool_calls") == .tool_calls);
    try std.testing.expect(FinishReason.fromJson("other") == .stop);
}
