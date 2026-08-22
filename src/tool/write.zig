const std = @import("std");
const Allocator = std.mem.Allocator;
const Tool = @import("tool.zig").Tool;
const ToolResult = @import("tool.zig").ToolResult;
const ToolSpec = @import("../provider/provider.zig").ToolSpec;
const Fs = @import("../fs/fs.zig").Fs;

/// Create or overwrite a file with the given content.
pub const WriteTool = struct {
    fs: Fs,

    pub fn init(fs: Fs) WriteTool {
        return .{ .fs = fs };
    }
    pub fn toTool(self: *WriteTool) Tool {
        return .{ .ctx = self, .vtable = &vtable };
    }
    const vtable = Tool.VTable{ .execute = execute, .schema = schema, .name = name };

    fn name(_: *anyopaque) []const u8 {
        return "write_file";
    }
    fn schema(_: *anyopaque) ToolSpec {
        return .{
            .name = "write_file",
            .description = "Create or overwrite a file at the given path with the given content.",
            .parameters_json_schema =
                \\{"type":"object","properties":{"path":{"type":"string"},"data":{"type":"string"}},"required":["path","data"]}
            ,
        };
    }
    fn execute(ctx: *anyopaque, alloc: Allocator, args_json: []const u8) !ToolResult {
        const self: *WriteTool = @ptrCast(@alignCast(ctx));
        const Args = struct { path: []const u8, data: []const u8 };
        var parsed = try std.json.parseFromSlice(Args, alloc, args_json, .{});
        defer parsed.deinit();
        self.fs.writeFile(alloc, parsed.value.path, parsed.value.data) catch |e| {
            return ToolResult{ .ok = false, .error_message = try std.fmt.allocPrint(alloc, "write_file failed: {s}", .{@errorName(e)}) };
        };
        return ToolResult{ .ok = true, .output = try std.fmt.allocPrint(alloc, "wrote {s}", .{parsed.value.path}) };
    }
};

test "WriteTool writes via Fs" {
    var fake = @import("../fs/fs.zig").FakeFs.init(std.testing.allocator, "/wd");
    defer fake.deinit();
    var wt = WriteTool.init(fake.toFs());
    const t = wt.toTool();
    const r = try t.execute(std.testing.allocator, "{\"path\":\"a.txt\",\"data\":\"hello\"}");
    defer std.testing.allocator.free(r.output);
    try std.testing.expect(r.ok);
    const got = try fake.readFile(std.testing.allocator, "a.txt");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("hello", got);
}
