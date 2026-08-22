const std = @import("std");
const Allocator = std.mem.Allocator;
const Tool = @import("tool.zig").Tool;
const ToolResult = @import("tool.zig").ToolResult;
const ToolSpec = @import("../provider/provider.zig").ToolSpec;
const Fs = @import("../fs/fs.zig").Fs;

pub const EditTool = struct {
    fs: Fs,

    pub fn init(fs: Fs) EditTool {
        return .{ .fs = fs };
    }
    pub fn toTool(self: *EditTool) Tool {
        return .{ .ctx = self, .vtable = &vtable };
    }
    const vtable = Tool.VTable{ .execute = execute, .schema = schema, .name = name };

    fn name(_: *anyopaque) []const u8 {
        return "edit_file";
    }
    fn schema(_: *anyopaque) ToolSpec {
        return .{
            .name = "edit_file",
            .description = "Replace the first occurrence of `old` with `new` in a file. Fails if `old` is not found exactly once.",
            .parameters_json_schema =
                \\{"type":"object","properties":{"path":{"type":"string"},"old":{"type":"string"},"new":{"type":"string"}},"required":["path","old","new"]}
            ,
        };
    }
    fn execute(ctx: *anyopaque, alloc: Allocator, args_json: []const u8) !ToolResult {
        const self: *EditTool = @ptrCast(@alignCast(ctx));
        const Args = struct { path: []const u8, old: []const u8, @"new": []const u8 };
        var parsed = try std.json.parseFromSlice(Args, alloc, args_json, .{});
        defer parsed.deinit();

        const original = self.fs.readFile(alloc, parsed.value.path) catch |e| {
            return ToolResult{ .ok = false, .error_message = try std.fmt.allocPrint(alloc, "edit_file read failed: {s}", .{@errorName(e)}) };
        };
        defer alloc.free(original);

        const count = std.mem.count(u8, original, parsed.value.old);
        if (count != 1) {
            return ToolResult{ .ok = false, .error_message = try std.fmt.allocPrint(alloc, "edit_file expected exactly 1 match, found {d}", .{count}) };
        }
        const replaced = try std.mem.replaceOwned(u8, alloc, original, parsed.value.old, parsed.value.@"new");
        defer alloc.free(replaced);
        try self.fs.writeFile(alloc, parsed.value.path, replaced);
        return ToolResult{ .ok = true, .output = try std.fmt.allocPrint(alloc, "edited {s}", .{parsed.value.path}) };
    }
};

test "EditTool replaces exactly once" {
    var fake = @import("../fs/fs.zig").FakeFs.init(std.testing.allocator, "/wd");
    defer fake.deinit();
    try fake.writeFile(std.testing.allocator, "f.txt", "hello world");
    var et = EditTool.init(fake.toFs());
    const t = et.toTool();
    const r = try t.execute(std.testing.allocator, "{\"path\":\"f.txt\",\"old\":\"world\",\"new\":\"ziki\"}");
    defer std.testing.allocator.free(r.output);
    try std.testing.expect(r.ok);
    const got = try fake.readFile(std.testing.allocator, "f.txt");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("hello ziki", got);
}
