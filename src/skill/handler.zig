const std = @import("std");
const Allocator = std.mem.Allocator;
const SkillRegistry = @import("registry.zig").SkillRegistry;

/// `/skill` command logic (FR-007, FR-008). Pure text generation: the shell
/// handler in the composition root emits the returned string, so this module
/// is fully unit-testable without the dispatcher or stdout.
///
///   /skill              -> usage
///   /skill list         -> every skill: name, description, source (+ warnings)
///   /skill show <name>  -> the skill's verbatim body
pub fn runSkillCommand(alloc: Allocator, registry: *const SkillRegistry, args: []const u8) ![]const u8 {
    var it = std.mem.tokenizeScalar(u8, args, ' ');
    const sub = it.next() orelse return usage(alloc);
    if (std.mem.eql(u8, sub, "list")) {
        return listText(alloc, registry);
    }
    if (std.mem.eql(u8, sub, "show")) {
        const name = it.next() orelse return usage(alloc);
        const s = registry.find(name) orelse return notFound(alloc, registry, name);
        return alloc.dupe(u8, s.body);
    }
    return usage(alloc);
}

fn usage(alloc: Allocator) ![]const u8 {
    return alloc.dupe(u8,
        \\usage: /skill list | /skill show <name>
        \\  /skill list         list discovered skills (name, description, source)
        \\  /skill show <name>  print a skill's full instructions
    );
}

fn listText(alloc: Allocator, registry: *const SkillRegistry) ![]const u8 {
    var buf = try std.ArrayList(u8).initCapacity(alloc, 0);
    errdefer buf.deinit(alloc);
    const w = buf.writer(alloc);
    const skills = registry.list();
    if (skills.len == 0) {
        try w.writeAll("no skills found — add SKILL.md files under .ziki/skills, .kimi-code/skills, or ~/.config/ziki/skills");
    } else {
        try w.print("skills ({d}):\n", .{skills.len});
        for (skills) |s| {
            try w.print("  {s} — {s} ({s})\n", .{ s.name, s.description, s.source });
        }
    }
    for (registry.warnings()) |warn| {
        try w.print("warning: {s}\n", .{warn});
    }
    return buf.toOwnedSlice(alloc);
}

fn notFound(alloc: Allocator, registry: *const SkillRegistry, missing: []const u8) ![]const u8 {
    var buf = try std.ArrayList(u8).initCapacity(alloc, 0);
    errdefer buf.deinit(alloc);
    const w = buf.writer(alloc);
    try w.print("skill not found: {s}\n", .{missing});
    const skills = registry.list();
    if (skills.len == 0) {
        try w.writeAll("no skills are currently loaded");
    } else {
        try w.writeAll("available skills: ");
        for (skills, 0..) |s, i| {
            if (i > 0) try w.writeAll(", ");
            try w.writeAll(s.name);
        }
    }
    return buf.toOwnedSlice(alloc);
}

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
    try A.write(fake, alloc, "root", "alpha", "first skill", "ALPHA BODY");
    try A.write(fake, alloc, "root", "beta", "second skill", "BETA BODY");
    try fake.writeFile(alloc, "root/broken/SKILL.md", "garbage without frontmatter");
    const roots = [_][]const u8{"root"};
    return SkillRegistry.load(alloc, fake.toFs(), &roots);
}

test "/skill list shows name, description, source and warnings" {
    const alloc = std.testing.allocator;
    var fake = @import("../fs/fs.zig").FakeFs.init(alloc, "/wd");
    defer fake.deinit();
    var reg = try makeRegistry(alloc, &fake);
    defer reg.deinit();

    const out = try runSkillCommand(alloc, &reg, "list");
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "skills (2):") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "alpha — first skill (root)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "beta — second skill (root)") != null);
    // The malformed skill is surfaced as a warning, not hidden.
    try std.testing.expect(std.mem.indexOf(u8, out, "warning: skipped root/broken/SKILL.md") != null);
}

test "/skill show prints the verbatim body" {
    const alloc = std.testing.allocator;
    var fake = @import("../fs/fs.zig").FakeFs.init(alloc, "/wd");
    defer fake.deinit();
    var reg = try makeRegistry(alloc, &fake);
    defer reg.deinit();

    const out = try runSkillCommand(alloc, &reg, "show alpha");
    defer alloc.free(out);
    try std.testing.expectEqualStrings("ALPHA BODY", out);
}

test "/skill show unknown lists available skills" {
    const alloc = std.testing.allocator;
    var fake = @import("../fs/fs.zig").FakeFs.init(alloc, "/wd");
    defer fake.deinit();
    var reg = try makeRegistry(alloc, &fake);
    defer reg.deinit();

    const out = try runSkillCommand(alloc, &reg, "show nope");
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "skill not found: nope") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "alpha") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "beta") != null);
}

test "/skill with no, missing, or unknown arguments prints usage" {
    const alloc = std.testing.allocator;
    var fake = @import("../fs/fs.zig").FakeFs.init(alloc, "/wd");
    defer fake.deinit();
    var reg = try makeRegistry(alloc, &fake);
    defer reg.deinit();

    const cases = [_][]const u8{ "", "show", "bogus", "   " };
    for (cases) |c| {
        const out = try runSkillCommand(alloc, &reg, c);
        defer alloc.free(out);
        try std.testing.expect(std.mem.indexOf(u8, out, "usage: /skill list") != null);
    }
}

test "/skill list with an empty registry explains where skills go" {
    const alloc = std.testing.allocator;
    var fake = @import("../fs/fs.zig").FakeFs.init(alloc, "/wd");
    defer fake.deinit();
    var reg = SkillRegistry.init(alloc);
    defer reg.deinit();

    const out = try runSkillCommand(alloc, &reg, "list");
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "no skills found") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, ".kimi-code/skills") != null);
}
