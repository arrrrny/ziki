const std = @import("std");
const Allocator = std.mem.Allocator;
const Tool = @import("../tool/tool.zig").Tool;
const ToolResult = @import("../tool/tool.zig").ToolResult;
const ToolSpec = @import("../provider/provider.zig").ToolSpec;
const SkillRegistry = @import("registry.zig").SkillRegistry;

/// Agent-facing skill fetch tool (FR-006): the model asks for a skill by name
/// and receives its verbatim body. Unknown names and malformed arguments
/// return a clear error result — never a crash, never silence — so the goal
/// loop keeps running (spec edge case).
pub const SkillTool = struct {
    registry: *const SkillRegistry,

    pub fn init(registry: *const SkillRegistry) SkillTool {
        return .{ .registry = registry };
    }
    pub fn toTool(self: *SkillTool) Tool {
        return .{ .ctx = self, .vtable = &vtable };
    }
    const vtable = Tool.VTable{ .execute = execute, .schema = schema, .name = name };

    fn name(_: *anyopaque) []const u8 {
        return "skill";
    }
    fn schema(_: *anyopaque) ToolSpec {
        return .{
            .name = "skill",
            .description = "Fetch the full instructions of a skill by name. The skills available to you are listed in the system prompt.",
            .parameters_json_schema =
                \\{"type":"object","properties":{"name":{"type":"string","description":"Name of the skill whose full instructions should be fetched"}},"required":["name"]}
            ,
        };
    }
    fn execute(ctx: *anyopaque, alloc: Allocator, args_json: []const u8) !ToolResult {
        const self: *SkillTool = @ptrCast(@alignCast(ctx));
        const Args = struct { name: []const u8 };
        const parsed = std.json.parseFromSlice(Args, alloc, args_json, .{}) catch {
            return ToolResult{
                .ok = false,
                .error_message = try alloc.dupe(u8, "skill tool: arguments must be JSON with a string field \"name\""),
            };
        };
        defer parsed.deinit();
        if (self.registry.find(parsed.value.name)) |s| {
            return ToolResult{ .ok = true, .output = try alloc.dupe(u8, s.body) };
        }
        return ToolResult{
            .ok = false,
            .error_message = try self.notFoundMessage(alloc, parsed.value.name),
        };
    }

    fn notFoundMessage(self: *const SkillTool, alloc: Allocator, missing: []const u8) ![]u8 {
        var buf = try std.ArrayList(u8).initCapacity(alloc, 0);
        errdefer buf.deinit(alloc);
        const w = buf.writer(alloc);
        try w.print("skill not found: {s}. available skills: ", .{missing});
        const skills = self.registry.list();
        if (skills.len == 0) {
            try w.writeAll("(none)");
        } else {
            for (skills, 0..) |s, i| {
                if (i > 0) try w.writeAll(", ");
                try w.writeAll(s.name);
            }
        }
        return buf.toOwnedSlice(alloc);
    }
};

// ---------------------------------------------------------------------------
// Tests (constitution Principle V: tests first, no exceptions).
// ---------------------------------------------------------------------------

fn makeRegistry(alloc: std.mem.Allocator, fake: *@import("../fs/fs.zig").FakeFs) !SkillRegistry {
    const A = struct {
        fn write(fs: *@import("../fs/fs.zig").FakeFs, a: std.mem.Allocator, dir: []const u8, name: []const u8, desc: []const u8, body: []const u8) !void {
            const p = try std.fmt.allocPrint(a, "{s}/{s}/SKILL.md", .{ dir, name });
            defer a.free(p);
            const c = try std.fmt.allocPrint(a, "---\nname: {s}\ndescription: {s}\n---\n{s}", .{ name, desc, body });
            defer a.free(c);
            try fs.writeFile(a, p, c);
        }
    };
    try A.write(fake, alloc, "root", "alpha", "first", "ALPHA BODY");
    try A.write(fake, alloc, "root", "beta", "second", "BETA BODY");
    const roots = [_][]const u8{"root"};
    return SkillRegistry.load(alloc, fake.toFs(), &roots);
}

test "SkillTool returns the verbatim body for a known skill" {
    const alloc = std.testing.allocator;
    var fake = @import("../fs/fs.zig").FakeFs.init(alloc, "/wd");
    defer fake.deinit();
    var reg = try makeRegistry(alloc, &fake);
    defer reg.deinit();

    var st = SkillTool.init(&reg);
    const t = st.toTool();
    const r = try t.execute(alloc, "{\"name\":\"alpha\"}");
    defer alloc.free(r.output);
    try std.testing.expect(r.ok);
    try std.testing.expectEqualStrings("ALPHA BODY", r.output);
}

test "SkillTool returns a clear error for an unknown skill" {
    const alloc = std.testing.allocator;
    var fake = @import("../fs/fs.zig").FakeFs.init(alloc, "/wd");
    defer fake.deinit();
    var reg = try makeRegistry(alloc, &fake);
    defer reg.deinit();

    var st = SkillTool.init(&reg);
    const t = st.toTool();
    const r = try t.execute(alloc, "{\"name\":\"nope\"}");
    defer alloc.free(r.error_message.?);
    try std.testing.expect(!r.ok);
    const msg = r.error_message.?;
    try std.testing.expect(std.mem.indexOf(u8, msg, "skill not found: nope") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "alpha") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "beta") != null);
}

test "SkillTool returns an error result for malformed arguments" {
    const alloc = std.testing.allocator;
    var fake = @import("../fs/fs.zig").FakeFs.init(alloc, "/wd");
    defer fake.deinit();
    var reg = try makeRegistry(alloc, &fake);
    defer reg.deinit();

    var st = SkillTool.init(&reg);
    const t = st.toTool();
    const r = try t.execute(alloc, "not json at all");
    defer alloc.free(r.error_message.?);
    try std.testing.expect(!r.ok);
    try std.testing.expect(std.mem.indexOf(u8, r.error_message.?, "\"name\"") != null);

    // Missing the required field entirely.
    const r2 = try t.execute(alloc, "{}");
    defer alloc.free(r2.error_message.?);
    try std.testing.expect(!r2.ok);
}

test "SkillTool schema advertises the name parameter" {
    const alloc = std.testing.allocator;
    var fake = @import("../fs/fs.zig").FakeFs.init(alloc, "/wd");
    defer fake.deinit();
    var reg = try makeRegistry(alloc, &fake);
    defer reg.deinit();

    var st = SkillTool.init(&reg);
    const t = st.toTool();
    try std.testing.expectEqualStrings("skill", t.name());
    const s = t.schema();
    try std.testing.expectEqualStrings("skill", s.name);
    try std.testing.expect(std.mem.indexOf(u8, s.parameters_json_schema, "\"name\"") != null);
}
