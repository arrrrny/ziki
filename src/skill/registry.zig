const std = @import("std");
const Allocator = std.mem.Allocator;
const Fs = @import("../fs/fs.zig").Fs;
const skill_mod = @import("skill.zig");
const Skill = skill_mod.Skill;

/// Deduplicated in-memory skill collection for one invocation (FR-002..FR-004).
/// Depends only on the `Fs` boundary (DIP) so all discovery and precedence
/// logic is FakeFs-testable. Never persisted; read-only with respect to the
/// filesystem (FR-009).
pub const SkillRegistry = struct {
    alloc: Allocator,
    skills: std.ArrayList(Skill),
    warnings_list: std.ArrayList([]const u8),

    pub fn init(alloc: Allocator) SkillRegistry {
        return .{ .alloc = alloc, .skills = .{}, .warnings_list = .{} };
    }

    pub fn deinit(self: *SkillRegistry) void {
        for (self.skills.items) |s| s.deinit(self.alloc);
        self.skills.deinit(self.alloc);
        for (self.warnings_list.items) |w| self.alloc.free(w);
        self.warnings_list.deinit(self.alloc);
    }

    /// Load skills from `roots` in precedence order: the first occurrence of a
    /// name wins (FR-004). Malformed or unreadable skills are skipped with a
    /// warning and never abort the run (FR-003). A root that cannot be read is
    /// treated as absent (spec edge case: fresh checkout). Within one root,
    /// skills load in alphabetical directory order so listings are
    /// deterministic.
    pub fn load(alloc: Allocator, fs: Fs, roots: []const []const u8) !SkillRegistry {
        var self = SkillRegistry.init(alloc);
        errdefer self.deinit();
        for (roots) |root| {
            const entries = fs.readDir(alloc, root) catch continue;
            defer {
                for (entries) |e| alloc.free(e);
                alloc.free(entries);
            }
            std.mem.sort([]const u8, entries, {}, strLessThan);
            for (entries) |entry| {
                const path = std.fmt.allocPrint(alloc, "{s}/{s}/SKILL.md", .{ root, entry }) catch |e| {
                    if (e == error.OutOfMemory) return e;
                    continue;
                };
                defer alloc.free(path);
                if (!fs.exists(path)) continue;
                const raw = fs.readFile(alloc, path) catch |e| {
                    try self.addWarning("skipped {s}: read failed: {s}", .{ path, @errorName(e) });
                    continue;
                };
                defer alloc.free(raw);
                const parsed = skill_mod.parse(alloc, root, raw) catch |e| {
                    try self.addWarning("skipped {s}: {s}", .{ path, @errorName(e) });
                    continue;
                };
                if (self.find(parsed.name) != null) {
                    // Lower-precedence duplicate: not exposed (FR-004).
                    parsed.deinit(alloc);
                    continue;
                }
                self.skills.append(alloc, parsed) catch |e| {
                    parsed.deinit(alloc);
                    if (e == error.OutOfMemory) return e;
                    continue;
                };
            }
        }
        return self;
    }

    fn addWarning(self: *SkillRegistry, comptime fmt: []const u8, args: anytype) !void {
        const w = std.fmt.allocPrint(self.alloc, fmt, args) catch |e| {
            return e;
        };
        self.warnings_list.append(self.alloc, w) catch |e| {
            self.alloc.free(w);
            return e;
        };
    }

    /// Exact-name lookup; frontmatter `name` is the key.
    pub fn find(self: *const SkillRegistry, name: []const u8) ?*const Skill {
        for (self.skills.items) |*s| {
            if (std.mem.eql(u8, s.name, name)) return s;
        }
        return null;
    }

    /// All exposed skills, in load order (root precedence, alphabetical within
    /// a root).
    pub fn list(self: *const SkillRegistry) []const Skill {
        return self.skills.items;
    }

    /// Skip warnings produced during load (FR-003), for listings.
    pub fn warnings(self: *const SkillRegistry) []const []const u8 {
        return self.warnings_list.items;
    }
};

fn strLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Default skill roots in precedence order (FR-002): project-local override
/// `.ziki/skills` (machine-local, gitignored by design), project-shared
/// `.kimi-code/skills` (committed, kimi-code compatible), user-global
/// `$HOME/.config/ziki/skills`. The caller owns the returned slice and each
/// path. When HOME is unset the user root is simply omitted.
pub fn defaultRoots(alloc: Allocator, cwd: []const u8) ![][]const u8 {
    var roots = std.ArrayList([]const u8){};
    errdefer {
        for (roots.items) |r| alloc.free(r);
        roots.deinit(alloc);
    }
    try roots.append(alloc, try std.fmt.allocPrint(alloc, "{s}/.ziki/skills", .{cwd}));
    try roots.append(alloc, try std.fmt.allocPrint(alloc, "{s}/.kimi-code/skills", .{cwd}));
    const home = std.process.getEnvVarOwned(alloc, "HOME") catch "";
    defer alloc.free(home);
    if (home.len > 0) {
        try roots.append(alloc, try std.fmt.allocPrint(alloc, "{s}/.config/ziki/skills", .{home}));
    }
    return roots.toOwnedSlice(alloc);
}

/// Format the agent-facing listing (FR-005): one `- name: description` line
/// per skill. Returns an empty string when there are no skills (FR-010: the
/// caller then skips the section entirely).
pub fn listingText(alloc: Allocator, registry: *const SkillRegistry) ![]const u8 {
    var buf = try std.ArrayList(u8).initCapacity(alloc, 0);
    errdefer buf.deinit(alloc);
    const w = buf.writer(alloc);
    for (registry.list()) |s| {
        try w.print("- {s}: {s}\n", .{ s.name, s.description });
    }
    return buf.toOwnedSlice(alloc);
}

// ---------------------------------------------------------------------------
// Tests (constitution Principle V: tests first, no exceptions).
// ---------------------------------------------------------------------------

fn writeSkill(fake: *@import("../fs/fs.zig").FakeFs, alloc: Allocator, dir: []const u8, name: []const u8, description: []const u8, body: []const u8) !void {
    const path = try std.fmt.allocPrint(alloc, "{s}/{s}/SKILL.md", .{ dir, name });
    defer alloc.free(path);
    const content = try std.fmt.allocPrint(alloc, "---\nname: {s}\ndescription: {s}\n---\n{s}", .{ name, description, body });
    defer alloc.free(content);
    try fake.writeFile(alloc, path, content);
}

test "load discovers skills across roots with precedence and dedup" {
    const alloc = std.testing.allocator;
    var fake = @import("../fs/fs.zig").FakeFs.init(alloc, "/wd");
    defer fake.deinit();
    // Same skill name in local project and user roots: local must win.
    try writeSkill(&fake, alloc, ".ziki/skills", "shared", "local override", "LOCAL BODY");
    try writeSkill(&fake, alloc, ".kimi-code/skills", "team", "shared project skill", "TEAM BODY");
    try writeSkill(&fake, alloc, "user/skills", "shared", "user copy", "USER BODY");
    try writeSkill(&fake, alloc, "user/skills", "personal", "user only", "USER ONLY BODY");

    const roots = [_][]const u8{ ".ziki/skills", ".kimi-code/skills", "user/skills" };
    var reg = try SkillRegistry.load(alloc, fake.toFs(), &roots);
    defer reg.deinit();

    try std.testing.expectEqual(@as(usize, 3), reg.list().len);
    // Precedence: .ziki copy of "shared" wins over the user copy.
    const shared = reg.find("shared").?;
    try std.testing.expectEqualStrings("LOCAL BODY", shared.body);
    try std.testing.expectEqualStrings(".ziki/skills", shared.source);
    const team = reg.find("team").?;
    try std.testing.expectEqualStrings(".kimi-code/skills", team.source);
    try std.testing.expectEqualStrings("USER ONLY BODY", reg.find("personal").?.body);
    // Deterministic order: .ziki root first (alphabetical within it), then
    // .kimi-code, then user root.
    try std.testing.expectEqualStrings("shared", reg.list()[0].name);
    try std.testing.expectEqualStrings("team", reg.list()[1].name);
    try std.testing.expectEqualStrings("personal", reg.list()[2].name);
}

test "load skips malformed skills with a warning and loads the rest" {
    const alloc = std.testing.allocator;
    var fake = @import("../fs/fs.zig").FakeFs.init(alloc, "/wd");
    defer fake.deinit();
    try writeSkill(&fake, alloc, "root", "good1", "fine", "b1");
    // Malformed: no frontmatter at all.
    try fake.writeFile(alloc, "root/broken/SKILL.md", "no frontmatter here");
    // Malformed: unterminated frontmatter.
    try fake.writeFile(alloc, "root/unterminated/SKILL.md", "---\nname: x\ndescription: y\nbody");
    // A directory entry without SKILL.md: ignored silently.
    try fake.writeFile(alloc, "root/notes/other.md", "not a skill");
    try writeSkill(&fake, alloc, "root", "good2", "also fine", "b2");

    const roots = [_][]const u8{"root"};
    var reg = try SkillRegistry.load(alloc, fake.toFs(), &roots);
    defer reg.deinit();

    try std.testing.expectEqual(@as(usize, 2), reg.list().len);
    try std.testing.expect(reg.find("good1") != null);
    try std.testing.expect(reg.find("good2") != null);
    try std.testing.expectEqual(@as(usize, 2), reg.warnings().len);
    try std.testing.expect(std.mem.indexOf(u8, reg.warnings()[0], "root/broken/SKILL.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, reg.warnings()[0], "NoFrontmatter") != null);
    try std.testing.expect(std.mem.indexOf(u8, reg.warnings()[1], "UnterminatedFrontmatter") != null);
}

test "load with absent roots yields an empty registry, no warnings" {
    const alloc = std.testing.allocator;
    var fake = @import("../fs/fs.zig").FakeFs.init(alloc, "/wd");
    defer fake.deinit();
    const roots = [_][]const u8{ ".ziki/skills", ".kimi-code/skills", "nowhere/skills" };
    var reg = try SkillRegistry.load(alloc, fake.toFs(), &roots);
    defer reg.deinit();
    try std.testing.expectEqual(@as(usize, 0), reg.list().len);
    try std.testing.expectEqual(@as(usize, 0), reg.warnings().len);
    try std.testing.expect(reg.find("anything") == null);
}

test "load never writes to the filesystem (FR-009)" {
    const alloc = std.testing.allocator;
    var fake = @import("../fs/fs.zig").FakeFs.init(alloc, "/wd");
    defer fake.deinit();
    try writeSkill(&fake, alloc, "root", "s1", "d", "b");
    const before = fake.files.count();
    const roots = [_][]const u8{"root"};
    var reg = try SkillRegistry.load(alloc, fake.toFs(), &roots);
    defer reg.deinit();
    try std.testing.expectEqual(before, fake.files.count());
}

test "frontmatter name is authoritative over directory name" {
    const alloc = std.testing.allocator;
    var fake = @import("../fs/fs.zig").FakeFs.init(alloc, "/wd");
    defer fake.deinit();
    try fake.writeFile(alloc, "root/dirname/SKILL.md", "---\nname: real-name\ndescription: d\n---\nbody");
    const roots = [_][]const u8{"root"};
    var reg = try SkillRegistry.load(alloc, fake.toFs(), &roots);
    defer reg.deinit();
    try std.testing.expect(reg.find("real-name") != null);
    try std.testing.expect(reg.find("dirname") == null);
}

test "listingText formats one line per skill" {
    const alloc = std.testing.allocator;
    var fake = @import("../fs/fs.zig").FakeFs.init(alloc, "/wd");
    defer fake.deinit();
    try writeSkill(&fake, alloc, "root", "alpha", "first skill", "a");
    try writeSkill(&fake, alloc, "root", "beta", "second skill", "b");
    const roots = [_][]const u8{"root"};
    var reg = try SkillRegistry.load(alloc, fake.toFs(), &roots);
    defer reg.deinit();
    const text = try listingText(alloc, &reg);
    defer alloc.free(text);
    try std.testing.expectEqualStrings("- alpha: first skill\n- beta: second skill\n", text);
}

test "defaultRoots orders local, shared, user" {
    const alloc = std.testing.allocator;
    const roots = try defaultRoots(alloc, "/proj");
    defer {
        for (roots) |r| alloc.free(r);
        alloc.free(roots);
    }
    try std.testing.expectEqual(@as(usize, 3), roots.len);
    try std.testing.expectEqualStrings("/proj/.ziki/skills", roots[0]);
    try std.testing.expectEqualStrings("/proj/.kimi-code/skills", roots[1]);
    // HOME is set by the test runner environment; if it is, the user root is
    // derived from it, otherwise omitted (both acceptable).
    if (roots.len == 3) {
        try std.testing.expect(std.mem.endsWith(u8, roots[2], "/.config/ziki/skills"));
    }
}
