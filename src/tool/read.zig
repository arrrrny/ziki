const std = @import("std");
const Allocator = std.mem.Allocator;
const Tool = @import("tool.zig").Tool;
const ToolResult = @import("tool.zig").ToolResult;
const ToolSpec = @import("../provider/provider.zig").ToolSpec;
const Fs = @import("../fs/fs.zig").Fs;

pub const ReadTool = struct {
    fs: Fs,

    pub fn init(fs: Fs) ReadTool {
        return .{ .fs = fs };
    }
    pub fn toTool(self: *ReadTool) Tool {
        return .{ .ctx = self, .vtable = &vtable };
    }
    const vtable = Tool.VTable{ .execute = execute, .schema = schema, .name = name };

    fn name(_: *anyopaque) []const u8 {
        return "read_file";
    }
    fn schema(_: *anyopaque) ToolSpec {
        return .{
            .name = "read_file",
            .description = "Read the contents of a file at the given path.",
            .parameters_json_schema =
                \\{"type":"object","properties":{"path":{"type":"string","description":"File path, relative to the working directory"}},"required":["path"]}
            ,
        };
    }
    fn execute(ctx: *anyopaque, alloc: Allocator, args_json: []const u8) !ToolResult {
        const self: *ReadTool = @ptrCast(@alignCast(ctx));
        const Args = struct { path: []const u8 };
        var parsed = try std.json.parseFromSlice(Args, alloc, args_json, .{});
        defer parsed.deinit();
        const data = self.fs.readFile(alloc, parsed.value.path) catch |e| {
            return ToolResult{ .ok = false, .error_message = try std.fmt.allocPrint(alloc, "read_file failed: {s}", .{@errorName(e)}) };
        };
        return ToolResult{ .ok = true, .output = data };
    }
};

test "ReadTool reads via Fs" {
    var fake = @import("../fs/fs.zig").FakeFs.init(std.testing.allocator, "/wd");
    defer fake.deinit();
    try fake.writeFile(std.testing.allocator, "f.txt", "content");
    var rt = ReadTool.init(fake.toFs());
    const t = rt.toTool();
    const r = try t.execute(std.testing.allocator, "{\"path\":\"f.txt\"}");
    defer std.testing.allocator.free(r.output);
    try std.testing.expect(r.ok);
    try std.testing.expectEqualStrings("content", r.output);
}
