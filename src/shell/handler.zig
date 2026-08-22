const std = @import("std");
const Allocator = std.mem.Allocator;
const Intent = @import("intent.zig").Intent;
const Result = @import("intent.zig").Result;

/// Command handler boundary (Dependency Inversion). The dispatcher depends only
/// on this interface; concrete handlers are injected at the composition root and
/// are fully substitutable (LSP). Any implementation MUST allocate
/// `Result.output` via the passed allocator so the REPL can free it uniformly.
pub const Handler = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        handle: *const fn (ctx: *anyopaque, alloc: Allocator, intent: Intent) anyerror!Result,
    };

    pub fn handle(self: Handler, alloc: Allocator, intent: Intent) !Result {
        return self.vtable.handle(self.ctx, alloc, intent);
    }
};
