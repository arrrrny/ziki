const std = @import("std");
const Allocator = std.mem.Allocator;
const Goal = @import("goal.zig").Goal;
const Status = @import("goal.zig").Status;
const Budgets = @import("goal.zig").Budgets;
const Usage = @import("goal.zig").Usage;
const Fs = @import("../fs/fs.zig").Fs;

/// Durable goal store boundary (DI). The executor depends on this, not on the
/// filesystem, so resume logic is testable (FR-006, SC-004).
pub const GoalRepository = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        save: *const fn (ctx: *anyopaque, alloc: Allocator, goal: Goal) anyerror!void,
        load: *const fn (ctx: *anyopaque, alloc: Allocator) anyerror!?Goal,
    };

    pub fn save(self: GoalRepository, alloc: Allocator, goal: Goal) !void {
        return self.vtable.save(self.ctx, alloc, goal);
    }
    pub fn load(self: GoalRepository, alloc: Allocator) !?Goal {
        return self.vtable.load(self.ctx, alloc);
    }
};

const Stored = struct {
    id: []const u8,
    objective: []const u8,
    criterion: ?[]const u8,
    status: []const u8,
    progress: []const u8,
    budgets: Budgets,
    used: Usage,
    created_at: i64,
    updated_at: i64,
    session_id: []const u8,
};

/// Filesystem-backed repository. State lives at `<dir>/goal.<session_id>.json`
/// so concurrent windows stay isolated (spec edge case).
pub const FsGoalRepository = struct {
    fs: Fs,
    dir: []const u8,
    session_id: []const u8,

    pub fn init(fs: Fs, dir: []const u8, session_id: []const u8) FsGoalRepository {
        return .{ .fs = fs, .dir = dir, .session_id = session_id };
    }
    pub fn toRepository(self: *FsGoalRepository) GoalRepository {
        return .{ .ctx = self, .vtable = &vtable };
    }
    const vtable = GoalRepository.VTable{ .save = save, .load = load };

    fn path(self: *FsGoalRepository, alloc: Allocator) ![]u8 {
        return std.fmt.allocPrint(alloc, "{s}/goal.{s}.json", .{ self.dir, self.session_id });
    }

    fn save(ctx: *anyopaque, alloc: Allocator, goal: Goal) !void {
        const self: *FsGoalRepository = @ptrCast(@alignCast(ctx));
        const stored = Stored{
            .id = goal.id,
            .objective = goal.objective,
            .criterion = goal.criterion,
            .status = goal.status.jsonString(),
            .progress = goal.progress,
            .budgets = goal.budgets,
            .used = goal.used,
            .created_at = goal.created_at,
            .updated_at = goal.updated_at,
            .session_id = goal.session_id,
        };
        const body = try std.json.Stringify.valueAlloc(alloc, stored, .{});
        defer alloc.free(body);
        const p = try self.path(alloc);
        defer alloc.free(p);
        try self.fs.writeFile(alloc, p, body);
    }

    fn load(ctx: *anyopaque, alloc: Allocator) !?Goal {
        const self: *FsGoalRepository = @ptrCast(@alignCast(ctx));
        const p = try self.path(alloc);
        defer alloc.free(p);
        if (!self.fs.exists(p)) return null;
        const raw = self.fs.readFile(alloc, p) catch return null;
        defer alloc.free(raw);
        var parsed = std.json.parseFromSlice(Stored, alloc, raw, .{ .ignore_unknown_fields = true }) catch return null;
        defer parsed.deinit();
        const s = parsed.value;
        return Goal{
            .id = try alloc.dupe(u8, s.id),
            .objective = try alloc.dupe(u8, s.objective),
            .criterion = if (s.criterion) |c| try alloc.dupe(u8, c) else null,
            .status = Status.fromJson(s.status) catch .active,
            .progress = try alloc.dupe(u8, s.progress),
            .budgets = s.budgets,
            .used = s.used,
            .created_at = s.created_at,
            .updated_at = s.updated_at,
            .session_id = try alloc.dupe(u8, s.session_id),
        };
    }
};

test "FsGoalRepository round-trip and isolation" {
    var fake = @import("../fs/fs.zig").FakeFs.init(std.testing.allocator, "/wd");
    defer fake.deinit();
    var repo_a_impl = FsGoalRepository.init(fake.toFs(), ".ziki", "sessA");
    const repo_a = repo_a_impl.toRepository();
    var repo_b_impl = FsGoalRepository.init(fake.toFs(), ".ziki", "sessB");
    const repo_b = repo_b_impl.toRepository();

    var g = try Goal.init(std.testing.allocator, "obj", "crit", "sessA");
    defer g.deinit(std.testing.allocator);
    g.status = .completed;
    try repo_a.save(std.testing.allocator, g);

    var loaded = (try repo_a.load(std.testing.allocator)).?;
    defer loaded.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("obj", loaded.objective);
    try std.testing.expect(loaded.status == .completed);

    // Different session sees no state (isolation).
    try std.testing.expect((try repo_b.load(std.testing.allocator)) == null);
}
