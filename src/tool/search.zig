const std = @import("std");
const Allocator = std.mem.Allocator;
const Tool = @import("tool.zig").Tool;
const ToolResult = @import("tool.zig").ToolResult;
const ToolSpec = @import("../provider/provider.zig").ToolSpec;
const Fs = @import("../fs/fs.zig").Fs;

/// Substring search within a file (MVP parity with Kimi's grep for the common
/// case). Returns matching line numbers and the matched lines.
pub const SearchTool = struct {
    fs: Fs,

    pub fn init(fs: Fs) SearchTool {
        return .{ .fs = fs };
    }
    pub fn toTool(self: *SearchTool) Tool {
        return .{ .ctx = self, .vtable = &vtable };
    }
    const vtable = Tool.VTable{ .execute = execute, .schema = schema, .name = name };

    fn name(_: *anyopaque) []const u8 {
        return "search_file";
    }
    fn schema(_: *anyopaque) ToolSpec {
        return .{
            .name = "search_file",
            .description = "Find lines in a file containing the given substring.",
            .parameters_json_schema =
                \\{"type":"object","properties":{"path":{"type":"string"},"pattern":{"type":"string"}},"required":["path","pattern"]}
            ,
        };
    }
    fn execute(ctx: *anyopaque, alloc: Allocator, args_json: []const u8) !ToolResult {
        const self: *SearchTool = @ptrCast(@alignCast(ctx));
        const Args = struct { path: []const u8, pattern: []const u8 };
        var parsed = try std.json.parseFromSlice(Args, alloc, args_json, .{});
        defer parsed.deinit();

        const content = self.fs.readFile(alloc, parsed.value.path) catch |e| {
            return ToolResult{ .ok = false, .error_message = try std.fmt.allocPrint(alloc, "search_file read failed: {s}", .{@errorName(e)}) };
        };
        defer alloc.free(content);

        var out = try std.ArrayList(u8).initCapacity(alloc, 0);
        var line_iter = std.mem.splitScalar(u8, content, '\n');
        var line_no: usize = 0;
        while (line_iter.next()) |line| {
            line_no += 1;
            if (std.mem.indexOf(u8, line, parsed.value.pattern) != null) {
                try std.fmt.format(out.writer(alloc), "{d}: {s}\n", .{ line_no, line });
            }
        }
        return ToolResult{ .ok = true, .output = try out.toOwnedSlice(alloc) };
    }
};

test "SearchTool finds matching lines" {
    var fake = @import("../fs/fs.zig").FakeFs.init(std.testing.allocator, "/wd");
    defer fake.deinit();
    try fake.writeFile(std.testing.allocator, "f.txt", "foo\nbar baz\nqux");
    var st = SearchTool.init(fake.toFs());
    const t = st.toTool();
    const r = try t.execute(std.testing.allocator, "{\"path\":\"f.txt\",\"pattern\":\"baz\"}");
    defer std.testing.allocator.free(r.output);
    try std.testing.expect(r.ok);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "2: bar baz") != null);
}
