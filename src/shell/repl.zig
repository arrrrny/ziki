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

/// Read one line (without trailing newline) from the reader. 0.16 removed the
/// old `std.io` reader plumbing; the loop speaks `std.Io.Reader` directly, so
/// buffering is the reader's job (the former `leftover` mechanism is gone).
/// Returns `null` at end of stream.
fn readLine(alloc: Allocator, r: *std.Io.Reader) !?[]u8 {
    // Manual line assembly over the raw Reader primitives: 0.16's
    // `takeDelimiterExclusive` spins on fixed readers (see spec 018 notes), so
    // this loop consumes buffered chunks, splitting on '\n' explicitly.
    var out = try std.ArrayList(u8).initCapacity(alloc, 0);
    errdefer out.deinit(alloc);
    while (true) {
        if (r.bufferedLen() == 0) {
            r.fill(1) catch |e| switch (e) {
                error.EndOfStream => break,
                else => return e,
            };
        }
        if (r.bufferedLen() == 0) break;
        const chunk = r.buffered();
        if (std.mem.indexOfScalar(u8, chunk, '\n')) |idx| {
            try out.appendSlice(alloc, chunk[0..idx]);
            r.toss(idx + 1);
            return try out.toOwnedSlice(alloc);
        }
        try out.appendSlice(alloc, chunk);
        r.toss(chunk.len);
    }
    if (out.items.len == 0) {
        out.deinit(alloc);
        return null;
    }
    return try out.toOwnedSlice(alloc);
}

/// Run the dispatch loop: read lines from `reader`, parse, dispatch to the
/// registered handler, write the `Result.output` to `output`. When `prompt` is
/// non-null it is written before each read (interactive mode). Empty lines and
/// non-slash messages are skipped/no-op'd without crashing. Stops on end-of-input
/// or a `Result.exit`.
pub fn run(
    alloc: Allocator,
    reader: *std.Io.Reader,
    output: Output,
    dispatcher: *Dispatcher,
    prompt: ?[]const u8,
) !void {
    while (true) {
        if (prompt) |p| output.write(p);
        const line = readLine(alloc, reader) catch break;
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
