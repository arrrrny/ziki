const std = @import("std");
const Allocator = std.mem.Allocator;
const Tool = @import("tool.zig").Tool;
const ToolResult = @import("tool.zig").ToolResult;
const ToolSpec = @import("../provider/provider.zig").ToolSpec;
const Fs = @import("../fs/fs.zig").Fs;

/// Run a shell command in the working directory and capture stdout/stderr +
/// exit code.
pub const BashTool = struct {
    fs: Fs,

    pub fn init(fs: Fs) BashTool {
        return .{ .fs = fs };
    }
    pub fn toTool(self: *BashTool) Tool {
        return .{ .ctx = self, .vtable = &vtable };
    }
    const vtable = Tool.VTable{ .execute = execute, .schema = schema, .name = name };

    fn name(_: *anyopaque) []const u8 {
        return "run_command";
    }
    fn schema(_: *anyopaque) ToolSpec {
        return .{
            .name = "run_command",
            .description = "Execute a shell command and return its combined output and exit code.",
            .parameters_json_schema =
                \\{"type":"object","properties":{"command":{"type":"string"}},"required":["command"]}
            ,
        };
    }
    fn execute(ctx: *anyopaque, alloc: Allocator, args_json: []const u8) !ToolResult {
        const self: *BashTool = @ptrCast(@alignCast(ctx));
        const Args = struct { command: []const u8 };
        var parsed = try std.json.parseFromSlice(Args, alloc, args_json, .{});
        defer parsed.deinit();

        var argv = [_][]const u8{ "/bin/sh", "-c", parsed.value.command };
        const result = std.process.Child.run(.{ .allocator = alloc, .argv = &argv }) catch |e| {
            return ToolResult{ .ok = false, .error_message = try std.fmt.allocPrint(alloc, "run_command failed: {s}", .{@errorName(e)}) };
        };
        const cwd = self.fs.cwd();
        _ = cwd;

        const combined = try std.fmt.allocPrint(alloc, "exit={d}\n{s}{s}", .{ result.term.Exited, result.stdout, result.stderr });
        alloc.free(result.stdout);
        alloc.free(result.stderr);
        const ok = switch (result.term) {
            .Exited => |code| code == 0,
            else => false,
        };
        return ToolResult{ .ok = ok, .output = combined };
    }
};

test "BashTool runs a command" {
    var fake = @import("../fs/fs.zig").FakeFs.init(std.testing.allocator, "/wd");
    var bt = BashTool.init(fake.toFs());
    const t = bt.toTool();
    const r = try t.execute(std.testing.allocator, "{\"command\":\"echo hello\"}");
    defer std.testing.allocator.free(r.output);
    try std.testing.expect(r.ok);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "hello") != null);
}
