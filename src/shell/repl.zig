const std = @import("std");
const Allocator = std.mem.Allocator;
const Dispatcher = @import("dispatcher.zig").Dispatcher;
const parser = @import("parser.zig");
const Intent = @import("intent.zig").Intent;
const Result = @import("intent.zig").Result;

/// Output sink boundary (Dependency Inversion). The REPL writes prompts and
/// results here; the composition root supplies stdout, tests supply a capture
/// buffer. Avoids reaching `stdout` directly so the loop is fully testable.
pub const Output = struct {
    ctx: *anyopaque,
    vtable: *const VTable,
    pub const VTable = struct {
        write: *const fn (ctx: *anyopaque, data: []const u8) void,
    };
    pub fn write(self: Output, data: []const u8) void {
        self.vtable.write(self.ctx, data);
    }
};

/// Read one line (without trailing newline) from any reader exposing a
/// `read(buffer) usize!usize` method (returns 0 at end of stream). `leftover`
/// carries bytes read but not yet consumed across calls (a single physical
/// read may contain several lines); the caller owns and frees it.
/// Returns `null` at end of stream.
fn readLine(alloc: Allocator, r: anytype, leftover: *[]u8) !?[]u8 {
    var line = try std.ArrayList(u8).initCapacity(alloc, 0);

    // 1) Consume any bytes buffered from a previous read.
    if (leftover.*.len > 0) {
        var nl: ?usize = null;
        for (leftover.*, 0..) |b, i| {
            if (b == '\n') {
                nl = i;
                break;
            }
        }
        if (nl) |i| {
            try line.appendSlice(alloc, leftover.*[0..i]);
            if (leftover.*.len > i + 1) {
                const dup = try alloc.dupe(u8, leftover.*[i + 1 ..]);
                alloc.free(leftover.*);
                leftover.* = dup;
            } else {
                alloc.free(leftover.*);
                leftover.* = &.{};
            }
            return try line.toOwnedSlice(alloc);
        }
        try line.appendSlice(alloc, leftover.*);
        alloc.free(leftover.*);
        leftover.* = &.{};
    }

    // 2) Read fresh chunks until a newline or end of stream.
    var chunk: [1024]u8 = undefined;
    while (true) {
        const n = r.read(&chunk) catch break;
        if (n == 0) break;
        var nl: ?usize = null;
        for (chunk[0..n], 0..) |b, i| {
            if (b == '\n') {
                nl = i;
                break;
            }
        }
        if (nl) |i| {
            try line.appendSlice(alloc, chunk[0..i]);
            if (n > i + 1) {
                if (leftover.*.len > 0) alloc.free(leftover.*);
                leftover.* = try alloc.dupe(u8, chunk[i + 1 .. n]);
            }
            return try line.toOwnedSlice(alloc);
        }
        try line.appendSlice(alloc, chunk[0..n]);
    }

    // 3) End of stream: return a final partial line if present.
    if (line.items.len == 0) {
        line.deinit(alloc);
        return null;
    }
    if (leftover.*.len > 0) alloc.free(leftover.*);
    leftover.* = &.{};
    return try line.toOwnedSlice(alloc);
}

/// Run the dispatch loop: read lines from `reader`, parse, dispatch to the
/// registered handler, write the `Result.output` to `output`. When `prompt` is
/// non-null it is written before each read (interactive mode). Empty lines and
/// non-slash messages are skipped/no-op'd without crashing. Stops on end-of-input
/// or a `Result.exit`.
pub fn run(
    alloc: Allocator,
    reader: anytype,
    output: Output,
    dispatcher: *Dispatcher,
    prompt: ?[]const u8,
) !void {
    var leftover: []u8 = &.{};
    defer if (leftover.len > 0) alloc.free(leftover);
    while (true) {
        if (prompt) |p| output.write(p);
        const line = readLine(alloc, reader, &leftover) catch break;
        if (line == null) break;
        defer alloc.free(line.?);

        const intent = (try parser.parseLine(line.?)) orelse continue;
        const result = dispatcher.dispatch(alloc, intent) catch |e| Result{
            .output = try std.fmt.allocPrint(alloc, "error: {s}", .{@errorName(e)}),
        };
        if (result.output.len > 0) {
            output.write(result.output);
            output.write("\n");
        }
        alloc.free(result.output);
        if (result.exit) break;
    }
}
