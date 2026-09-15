const std = @import("std");
const Allocator = std.mem.Allocator;
const Goal = @import("goal.zig").Goal;
const Status = @import("goal.zig").Status;
const Budgets = @import("goal.zig").Budgets;
const Usage = @import("goal.zig").Usage;
const Fs = @import("../fs/fs.zig").Fs;
const provider = @import("../provider/provider.zig");

/// Durable goal store boundary (DI). The executor depends on this, not on the
/// filesystem, so resume logic is testable (FR-006, SC-004).
pub const GoalRepository = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        save: *const fn (ctx: *anyopaque, alloc: Allocator, goal: Goal) anyerror!void,
        load: *const fn (ctx: *anyopaque, alloc: Allocator) anyerror!?Goal,
        /// Persist the conversation transcript of `goal_id`. Called by the
        /// executor after each turn so a later resume replays it (spec 005
        /// FR-008: resume from saved progress, without re-definition).
        save_history: *const fn (ctx: *anyopaque, alloc: Allocator, goal_id: []const u8, messages: []const provider.ChatMessage) anyerror!void,
        /// Load the transcript previously stored for `goal_id`. Returns null
        /// when none is stored, the file is corrupt, or the stored goal_id
        /// does not match (no cross-goal replay). Caller owns the returned
        /// slice and every message in it.
        load_history: *const fn (ctx: *anyopaque, alloc: Allocator, goal_id: []const u8) anyerror!?[]provider.ChatMessage,
        /// Remove the stored transcript (fresh goal start / terminal state).
        clear_history: *const fn (ctx: *anyopaque, alloc: Allocator) anyerror!void,
    };

    pub fn save(self: GoalRepository, alloc: Allocator, goal: Goal) !void {
        return self.vtable.save(self.ctx, alloc, goal);
    }
    pub fn load(self: GoalRepository, alloc: Allocator) !?Goal {
        return self.vtable.load(self.ctx, alloc);
    }
    pub fn saveHistory(self: GoalRepository, alloc: Allocator, goal_id: []const u8, messages: []const provider.ChatMessage) !void {
        return self.vtable.save_history(self.ctx, alloc, goal_id, messages);
    }
    pub fn loadHistory(self: GoalRepository, alloc: Allocator, goal_id: []const u8) !?[]provider.ChatMessage {
        return self.vtable.load_history(self.ctx, alloc, goal_id);
    }
    pub fn clearHistory(self: GoalRepository, alloc: Allocator) !void {
        return self.vtable.clear_history(self.ctx, alloc);
    }
};

/// Frees a history slice returned by `loadHistory` (messages and contents).
pub fn freeHistory(alloc: Allocator, messages: []provider.ChatMessage) void {
    for (messages) |m| {
        alloc.free(m.content);
        if (m.tool_call_id) |id| alloc.free(id);
        if (m.tool_calls) |tcs| {
            for (tcs) |tc| {
                alloc.free(tc.id);
                alloc.free(tc.name);
                alloc.free(tc.arguments_json);
            }
            alloc.free(tcs);
        }
    }
    alloc.free(messages);
}

const HistoryEntry = struct {
    role: []const u8,
    content: []const u8 = "",
    tool_calls: ?[]StoredToolCall = null,
    tool_call_id: ?[]const u8 = null,
};
const StoredToolCall = struct {
    id: []const u8,
    name: []const u8,
    arguments_json: []const u8,
};
const StoredHistory = struct {
    goal_id: []const u8,
    messages: []HistoryEntry,
};

fn roleToJson(r: provider.Role) []const u8 {
    return r.jsonString();
}

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
    const vtable = GoalRepository.VTable{ .save = save, .load = load, .save_history = save_history, .load_history = load_history, .clear_history = clear_history };

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

    // -----------------------------------------------------------------------
    // Conversation history persistence (spec 013: resume round-trip).
    // -----------------------------------------------------------------------

    fn historyPath(self: *FsGoalRepository, alloc: Allocator) ![]u8 {
        return std.fmt.allocPrint(alloc, "{s}/history.{s}.json", .{ self.dir, self.session_id });
    }

    fn save_history(ctx: *anyopaque, alloc: Allocator, goal_id: []const u8, messages: []const provider.ChatMessage) !void {
        const self: *FsGoalRepository = @ptrCast(@alignCast(ctx));
        const entries = try alloc.alloc(HistoryEntry, messages.len);
        defer alloc.free(entries);
        for (messages, 0..) |m, i| {
            var tcs: ?[]StoredToolCall = null;
            if (m.tool_calls) |src| {
                const owned = try alloc.alloc(StoredToolCall, src.len);
                for (src, 0..) |tc, j| {
                    owned[j] = .{ .id = tc.id, .name = tc.name, .arguments_json = tc.arguments_json };
                }
                tcs = owned;
            }
            entries[i] = .{
                .role = roleToJson(m.role),
                .content = m.content,
                .tool_calls = tcs,
                .tool_call_id = m.tool_call_id,
            };
        }
        // Free the temporary tool-call slices after stringification.
        defer for (entries) |e| {
            if (e.tool_calls) |tcs| alloc.free(tcs);
        };
        const stored = StoredHistory{ .goal_id = goal_id, .messages = entries };
        const body = try std.json.Stringify.valueAlloc(alloc, stored, .{});
        defer alloc.free(body);
        const p = try self.historyPath(alloc);
        defer alloc.free(p);
        try self.fs.writeFile(alloc, p, body);
    }

    fn load_history(ctx: *anyopaque, alloc: Allocator, goal_id: []const u8) !?[]provider.ChatMessage {
        const self: *FsGoalRepository = @ptrCast(@alignCast(ctx));
        const p = try self.historyPath(alloc);
        defer alloc.free(p);
        if (!self.fs.exists(p)) return null;
        const raw = self.fs.readFile(alloc, p) catch return null;
        defer alloc.free(raw);
        var parsed = std.json.parseFromSlice(StoredHistory, alloc, raw, .{ .ignore_unknown_fields = true }) catch return null;
        defer parsed.deinit();
        if (!std.mem.eql(u8, parsed.value.goal_id, goal_id)) return null;
        const out = try alloc.alloc(provider.ChatMessage, parsed.value.messages.len);
        errdefer alloc.free(out);
        for (parsed.value.messages, 0..) |e, i| {
            var tcs: ?[]provider.ToolCall = null;
            if (e.tool_calls) |src| {
                const owned = try alloc.alloc(provider.ToolCall, src.len);
                for (src, 0..) |tc, j| {
                    owned[j] = .{
                        .id = try alloc.dupe(u8, tc.id),
                        .name = try alloc.dupe(u8, tc.name),
                        .arguments_json = try alloc.dupe(u8, tc.arguments_json),
                    };
                }
                tcs = owned;
            }
            out[i] = .{
                .role = provider.Role.fromJson(e.role) catch .user,
                .content = try alloc.dupe(u8, e.content),
                .tool_calls = tcs,
                .tool_call_id = if (e.tool_call_id) |id| try alloc.dupe(u8, id) else null,
            };
        }
        return out;
    }

    fn clear_history(ctx: *anyopaque, alloc: Allocator) !void {
        const self: *FsGoalRepository = @ptrCast(@alignCast(ctx));
        const p = try self.historyPath(alloc);
        defer alloc.free(p);
        if (self.fs.exists(p)) try self.fs.remove(p);
    }

    /// History-capable repository view (same storage, same extended vtable).
    pub fn toHistoryRepository(self: *FsGoalRepository) GoalRepository {
        return .{ .ctx = self, .vtable = &vtable };
    }
};

// ---------------------------------------------------------------------------

test "history round-trips through the repository (B1)" {
    var fake = @import("../fs/fs.zig").FakeFs.init(std.testing.allocator, "/wd");
    defer fake.deinit();
    var repo_impl = FsGoalRepository.init(fake.toFs(), ".ziki", "sess1");
    const repo = repo_impl.toHistoryRepository();

    const tcs = [_]provider.ToolCall{.{ .id = "c1", .name = "run_command", .arguments_json = "{\"command\":\"ls\"}" }};
    const msgs = [_]provider.ChatMessage{
        .{ .role = .system, .content = "sys prompt" },
        .{ .role = .user, .content = "Goal: do a thing" },
        .{ .role = .assistant, .content = "", .tool_calls = &tcs },
        .{ .role = .tool, .content = "exit=0\nfile", .tool_call_id = "c1" },
        .{ .role = .assistant, .content = "done" },
    };
    try repo.saveHistory(std.testing.allocator, "goal-42", &msgs);

    const loaded = (try repo.loadHistory(std.testing.allocator, "goal-42")).?;
    defer freeHistory(std.testing.allocator, loaded);
    try std.testing.expectEqual(msgs.len, loaded.len);
    try std.testing.expectEqualStrings("sys prompt", loaded[0].content);
    try std.testing.expect(loaded[0].role == .system);
    try std.testing.expectEqualStrings("Goal: do a thing", loaded[1].content);
    try std.testing.expect(loaded[2].tool_calls != null);
    try std.testing.expectEqualStrings("run_command", loaded[2].tool_calls.?[0].name);
    try std.testing.expectEqualStrings("c1", loaded[3].tool_call_id.?);
    try std.testing.expectEqualStrings("done", loaded[4].content);
}

test "load_history rejects a foreign goal_id (B2)" {
    var fake = @import("../fs/fs.zig").FakeFs.init(std.testing.allocator, "/wd");
    defer fake.deinit();
    var repo_impl = FsGoalRepository.init(fake.toFs(), ".ziki", "sess1");
    const repo = repo_impl.toHistoryRepository();
    const msgs = [_]provider.ChatMessage{.{ .role = .user, .content = "hi" }};
    try repo.saveHistory(std.testing.allocator, "goal-a", &msgs);
    try std.testing.expect((try repo.loadHistory(std.testing.allocator, "goal-b")) == null);
}

test "load_history tolerates missing and corrupt files (B3)" {
    var fake = @import("../fs/fs.zig").FakeFs.init(std.testing.allocator, "/wd");
    defer fake.deinit();
    var repo_impl = FsGoalRepository.init(fake.toFs(), ".ziki", "sess1");
    const repo = repo_impl.toHistoryRepository();
    // Missing: null, not an error.
    try std.testing.expect((try repo.loadHistory(std.testing.allocator, "goal-x")) == null);
    // Corrupt: null, not an error.
    try fake.toFs().writeFile(std.testing.allocator, ".ziki/history.sess1.json", "{{not json");
    try std.testing.expect((try repo.loadHistory(std.testing.allocator, "goal-x")) == null);
}

test "clear_history removes the transcript (B4)" {
    var fake = @import("../fs/fs.zig").FakeFs.init(std.testing.allocator, "/wd");
    defer fake.deinit();
    var repo_impl = FsGoalRepository.init(fake.toFs(), ".ziki", "sess1");
    const repo = repo_impl.toHistoryRepository();
    const msgs = [_]provider.ChatMessage{.{ .role = .user, .content = "hi" }};
    try repo.saveHistory(std.testing.allocator, "goal-a", &msgs);
    try repo.clearHistory(std.testing.allocator);
    try std.testing.expect((try repo.loadHistory(std.testing.allocator, "goal-a")) == null);
    // Clearing when nothing is stored is not an error.
    try repo.clearHistory(std.testing.allocator);
}

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
