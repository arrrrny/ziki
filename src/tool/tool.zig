const std = @import("std");
const Allocator = std.mem.Allocator;
const ToolSpec = @import("../provider/provider.zig").ToolSpec;

/// Outcome of running a tool.
pub const ToolResult = struct {
    ok: bool,
    output: []const u8 = "",
    error_message: ?[]const u8 = null,
};

/// A coding capability available to the agent (FR-007). Narrow interface:
/// the executor depends only on `execute` (ISP).
pub const Tool = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        execute: *const fn (ctx: *anyopaque, alloc: Allocator, args_json: []const u8) anyerror!ToolResult,
        schema: *const fn (ctx: *anyopaque) ToolSpec,
        name: *const fn (ctx: *anyopaque) []const u8,
    };

    pub fn execute(self: Tool, alloc: Allocator, args_json: []const u8) !ToolResult {
        return self.vtable.execute(self.ctx, alloc, args_json);
    }
    pub fn schema(self: Tool) ToolSpec {
        return self.vtable.schema(self.ctx);
    }
    pub fn name(self: Tool) []const u8 {
        return self.vtable.name(self.ctx);
    }
};
