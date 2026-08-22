const std = @import("std");
const Allocator = std.mem.Allocator;
const Intent = @import("intent.zig").Intent;
const Result = @import("intent.zig").Result;
const Handler = @import("handler.zig").Handler;
const parser = @import("parser.zig");
const Dispatcher = @import("dispatcher.zig").Dispatcher;
const Repl = @import("repl.zig");
const Output = @import("repl.zig").Output;

// --- fake handler used across dispatcher/REPL tests ---

const TestState = struct {
    last_command: ?[]const u8 = null,
    call_count: usize = 0,
};

fn fakeHandle(ctx_: *anyopaque, alloc: Allocator, intent: Intent) !Result {
    const st: *TestState = @ptrCast(@alignCast(ctx_));
    st.last_command = intent.command;
    st.call_count += 1;
    const out = try std.fmt.allocPrint(alloc, "handled:{s}", .{intent.command});
    return Result{ .output = out };
}
const fake_vtable = Handler.VTable{ .handle = fakeHandle };

// ===================== US1: parsing =====================

test "parseLine parses the documented command set" {
    var i = (try parser.parseLine("/goal add a parser to the project")).?;
    try std.testing.expectEqualStrings("goal", i.command);
    try std.testing.expectEqualStrings("add a parser to the project", i.args);

    i = (try parser.parseLine("/stop")).?;
    try std.testing.expectEqualStrings("stop", i.command);
    try std.testing.expectEqualStrings("", i.args);

    i = (try parser.parseLine("/provider openai")).?;
    try std.testing.expectEqualStrings("provider", i.command);
    try std.testing.expectEqualStrings("openai", i.args);

    i = (try parser.parseLine("/goals")).?;
    try std.testing.expectEqualStrings("goals", i.command);

    i = (try parser.parseLine("/help")).?;
    try std.testing.expectEqualStrings("help", i.command);
}

test "parseLine edge cases: empty, message, malformed" {
    // empty / whitespace-only -> no intent
    try std.testing.expect((try parser.parseLine("   ")) == null);
    try std.testing.expect((try parser.parseLine("")) == null);

    // non-slash line -> message intent (command "")
    const m = (try parser.parseLine("just some text")).?;
    try std.testing.expectEqualStrings("", m.command);
    try std.testing.expectEqualStrings("just some text", m.args);

    // malformed: bare slash or slash with no name -> error
    try std.testing.expectError(error.MalformedCommand, parser.parseLine("/"));
    try std.testing.expectError(error.MalformedCommand, parser.parseLine("/ "));
}

// ===================== US2: dispatch =====================

test "dispatcher invokes only the matching handler" {
    const a = std.testing.allocator;
    var st_goal: TestState = .{};
    var st_stop: TestState = .{};
    var d = Dispatcher.init(a);
    defer d.deinit();
    try d.register("goal", .{ .ctx = &st_goal, .vtable = &fake_vtable });
    try d.register("stop", .{ .ctx = &st_stop, .vtable = &fake_vtable });

    const r = try d.dispatch(a, Intent{ .command = "stop", .args = "", .raw = "/stop" });
    defer a.free(r.output);
    try std.testing.expectEqualStrings("handled:stop", r.output);
    try std.testing.expectEqual(@as(usize, 1), st_stop.call_count);
    try std.testing.expectEqual(@as(usize, 0), st_goal.call_count);
}

test "dispatcher reports unknown command without invoking any handler" {
    const a = std.testing.allocator;
    var st: TestState = .{};
    var d = Dispatcher.init(a);
    defer d.deinit();
    try d.register("goal", .{ .ctx = &st, .vtable = &fake_vtable });

    const r = try d.dispatch(a, Intent{ .command = "nope", .args = "", .raw = "/nope" });
    defer a.free(r.output);
    try std.testing.expectEqual(@as(usize, 0), st.call_count);
    try std.testing.expect(std.mem.startsWith(u8, r.output, "unknown command"));
}

test "dispatcher rejects duplicate registration" {
    const a = std.testing.allocator;
    var st: TestState = .{};
    var d = Dispatcher.init(a);
    defer d.deinit();
    try d.register("goal", .{ .ctx = &st, .vtable = &fake_vtable });
    try std.testing.expectError(error.DuplicateHandler, d.register("goal", .{ .ctx = &st, .vtable = &fake_vtable }));
}

test "non-slash line routes to handler registered under empty key" {
    const a = std.testing.allocator;
    var def: TestState = .{};
    var d = Dispatcher.init(a);
    defer d.deinit();
    try d.register("", .{ .ctx = &def, .vtable = &fake_vtable });

    const r = try d.dispatch(a, Intent{ .command = "", .args = "hello", .raw = "hello" });
    defer a.free(r.output);
    try std.testing.expectEqual(@as(usize, 1), def.call_count);
}

// ===================== US3: REPL loop =====================

const Capture = struct {
    alloc: Allocator,
    buf: std.ArrayList(u8),
    fn init(a: Allocator) Capture {
        return .{ .alloc = a, .buf = std.ArrayList(u8).initCapacity(a, 0) };
    }
    fn writeFn(ctx_: *anyopaque, data: []const u8) void {
        const self: *Capture = @ptrCast(@alignCast(ctx_));
        self.buf.appendSlice(self.alloc, data) catch {};
    }
};
const capture_vtable = Output.VTable{ .write = Capture.writeFn };

test "repl processes scripted input in order, skips empty, stops on EOF" {
    const a = std.testing.allocator;
    const input = "/help\n\n/provider kimi\n/stop\n";
    var stream = std.io.fixedBufferStream(@as([]const u8, input));
    const reader = stream.reader();
    var cap = Capture.init(a);
    defer cap.buf.deinit(a);
    const out = Output{ .ctx = &cap, .vtable = &capture_vtable };

    var st_help: TestState = .{};
    var st_prov: TestState = .{};
    var st_stop: TestState = .{};
    var d = Dispatcher.init(a);
    defer d.deinit();
    try d.register("help", .{ .ctx = &st_help, .vtable = &fake_vtable });
    try d.register("provider", .{ .ctx = &st_prov, .vtable = &fake_vtable });
    try d.register("stop", .{ .ctx = &st_stop, .vtable = &fake_vtable });

    try Repl.run(a, reader, out, &d, null);

    // each command dispatched exactly once; empty line skipped
    try std.testing.expectEqual(@as(usize, 1), st_help.call_count);
    try std.testing.expectEqual(@as(usize, 1), st_prov.call_count);
    try std.testing.expectEqual(@as(usize, 1), st_stop.call_count);

    // outputs captured in order
    const got = cap.buf.items;
    const h = std.mem.indexOf(u8, got, "handled:help");
    const p = std.mem.indexOf(u8, got, "handled:provider");
    const s = std.mem.indexOf(u8, got, "handled:stop");
    try std.testing.expect(h != null and p != null and s != null);
    try std.testing.expect(h.? < p.? and p.? < s.?);
}
