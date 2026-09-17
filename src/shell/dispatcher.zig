const std = @import("std");
const Allocator = std.mem.Allocator;
const Handler = @import("handler.zig").Handler;
const Intent = @import("intent.zig").Intent;
const Result = @import("intent.zig").Result;

/// Routes a parsed `Intent` to the handler registered for its command. Contains
/// zero command-specific logic (SC-005); it only performs a key lookup.
/// (0.16: the managed `StringArrayHashMap` is gone; the unmanaged
/// `array_hash_map.String` map is used, with the allocator captured at init so
/// the public `init/register/dispatch/deinit` surface is unchanged.)
pub const Dispatcher = struct {
    alloc: Allocator,
    handlers: std.array_hash_map.String(Handler),

    pub fn init(alloc: Allocator) Dispatcher {
        return .{ .alloc = alloc, .handlers = std.array_hash_map.String(Handler).empty };
    }

    /// Register `handler` for `command`. Rejects a duplicate registration so
    /// routing stays unambiguous (spec edge case). A handler registered under
    /// the empty key `""` receives non-slash (message) lines.
    pub fn register(self: *Dispatcher, command: []const u8, handler: Handler) !void {
        if (self.handlers.contains(command)) return error.DuplicateHandler;
        try self.handlers.put(self.alloc, command, handler);
    }

    /// Route `intent` to its handler. Unknown command -> a clear "unknown
    /// command" result with no handler invoked. Non-slash lines (`command = ""`)
    /// route to a handler registered under `""` if present, else a no-op.
    pub fn dispatch(self: *Dispatcher, alloc: Allocator, intent: Intent) !Result {
        if (self.handlers.get(intent.command)) |h| {
            return h.handle(alloc, intent);
        }
        if (intent.command.len == 0) {
            return Result{ .output = try alloc.dupe(u8, "") };
        }
        const msg = try std.fmt.allocPrint(alloc, "unknown command: /{s}", .{intent.command});
        return Result{ .output = msg };
    }

    pub fn deinit(self: *Dispatcher) void {
        self.handlers.deinit(self.alloc);
    }
};
