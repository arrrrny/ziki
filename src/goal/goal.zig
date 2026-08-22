const std = @import("std");

/// Lifecycle state of a goal (FR-003). Terminal states are completed/blocked/aborted.
pub const Status = enum {
    active,
    completed,
    blocked,
    aborted,

    pub fn isTerminal(self: Status) bool {
        return self != .active;
    }
    pub fn jsonString(self: Status) []const u8 {
        return switch (self) {
            .active => "active",
            .completed => "completed",
            .blocked => "blocked",
            .aborted => "aborted",
        };
    }
    pub fn fromJson(s: []const u8) !Status {
        if (std.mem.eql(u8, s, "active")) return .active;
        if (std.mem.eql(u8, s, "completed")) return .completed;
        if (std.mem.eql(u8, s, "blocked")) return .blocked;
        if (std.mem.eql(u8, s, "aborted")) return .aborted;
        return error.InvalidStatus;
    }
};

/// Resource caps that end a goal gracefully when exceeded (spec edge cases).
pub const Budgets = struct {
    max_turns: u32 = 50,
    max_tokens: u64 = 200_000,
    max_seconds: u64 = 1800,
};

/// Counters consumed against Budgets during a run.
pub const Usage = struct {
    turns: u32 = 0,
    tokens: u64 = 0,
    seconds: u64 = 0,
};

/// The unit of autonomous work (spec Key Entity: Goal).
pub const Goal = struct {
    id: []const u8,
    objective: []const u8,
    criterion: ?[]const u8 = null,
    status: Status = .active,
    progress: []const u8 = "",
    budgets: Budgets = .{},
    used: Usage = .{},
    created_at: i64 = 0,
    updated_at: i64 = 0,
    session_id: []const u8 = "",

    pub fn init(alloc: std.mem.Allocator, objective: []const u8, criterion: ?[]const u8, session_id: []const u8) !Goal {
        const id = try std.fmt.allocPrint(alloc, "goal-{d}", .{std.time.nanoTimestamp()});
        return Goal{
            .id = id,
            .objective = try alloc.dupe(u8, objective),
            .criterion = if (criterion) |c| try alloc.dupe(u8, c) else null,
            .progress = try alloc.dupe(u8, ""),
            .session_id = try alloc.dupe(u8, session_id),
            .created_at = std.time.timestamp(),
            .updated_at = std.time.timestamp(),
        };
    }

    /// Frees every heap-owned field. `progress` is always heap-allocated (see
    /// `init`), so it is safe to free unconditionally.
    pub fn deinit(self: *Goal, alloc: std.mem.Allocator) void {
        alloc.free(self.id);
        alloc.free(self.objective);
        if (self.criterion) |c| alloc.free(c);
        alloc.free(self.progress);
        alloc.free(self.session_id);
    }
};

test "Status json round-trip" {
    try std.testing.expectEqualStrings("completed", Status.completed.jsonString());
    try std.testing.expect((try Status.fromJson("blocked")) == .blocked);
    try std.testing.expectError(error.InvalidStatus, Status.fromJson("weird"));
    try std.testing.expect(Status.active.isTerminal() == false);
    try std.testing.expect(Status.aborted.isTerminal() == true);
}

test "Goal.init builds a goal" {
    var g = try Goal.init(std.testing.allocator, "do x", "x done", "s1");
    defer g.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("do x", g.objective);
    try std.testing.expectEqualStrings("x done", g.criterion.?);
    try std.testing.expectEqualStrings("s1", g.session_id);
}
