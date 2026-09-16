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
    /// The backend reported a finish_reason this client does not know
    /// (spec 014 US2): surfaced to the caller, never silently `.stop`.
    unknown,

    pub fn fromJson(s: []const u8) FinishReason {
        if (std.mem.eql(u8, s, "tool_calls")) return .tool_calls;
        if (std.mem.eql(u8, s, "length")) return .length;
        if (std.mem.eql(u8, s, "stop")) return .stop;
        return .unknown;
    }
};

/// Token usage reported by the provider for one completion (spec 013 D2).
/// When the backend reports nothing, the executor estimates from message size.
pub const TokenUsage = struct {
    prompt_tokens: u64 = 0,
    completion_tokens: u64 = 0,

    pub fn total(self: TokenUsage) u64 {
        return self.prompt_tokens + self.completion_tokens;
    }
};

/// The model's reply for one turn.
pub const ChatResponse = struct {
    message: ChatMessage,
    finish_reason: FinishReason = .stop,
    /// Provider-reported usage, when the backend supplies it. Null means the
    /// caller must estimate (see executor token accounting).
    usage: ?TokenUsage = null,
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
        /// Optional (spec 014 US4): the last error-path hint (e.g. the
        /// gateway's available-models list after a ModelNotFound). Null when
        /// the provider has none — default for fakes.
        error_hint: ?*const fn (ctx: *anyopaque) ?[]const u8 = null,
    };

    pub fn complete(self: Provider, alloc: Allocator, req: CompletionRequest) !ChatResponse {
        return self.vtable.complete(self.ctx, alloc, req);
    }
    pub fn name(self: Provider) []const u8 {
        return self.vtable.name(self.ctx);
    }
    pub fn errorHint(self: Provider) ?[]const u8 {
        const f = self.vtable.error_hint orelse return null;
        return f(self.ctx);
    }
};

test "Role/FinishReason json mapping" {
    try std.testing.expectEqualStrings("assistant", Role.assistant.jsonString());
    try std.testing.expect(FinishReason.fromJson("tool_calls") == .tool_calls);
    try std.testing.expect(FinishReason.fromJson("length") == .length);
    try std.testing.expect(FinishReason.fromJson("stop") == .stop);
    // Spec 014 US2: unknown values are surfaced, never silently `.stop`.
    try std.testing.expect(FinishReason.fromJson("other") == .unknown);
    try std.testing.expect(FinishReason.fromJson("") == .unknown);
}
