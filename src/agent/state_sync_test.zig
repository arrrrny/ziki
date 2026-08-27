const std = @import("std");
const Allocator = std.mem.Allocator;
const state = @import("state.zig");
const provider = @import("../provider/provider.zig");
const Tool = @import("../tool/tool.zig").Tool;
const WriteTool = @import("../tool/write.zig").WriteTool;
const GoalExecutor = @import("executor.zig").GoalExecutor;
const Goal = @import("../goal/goal.zig").Goal;
const FsGoalRepository = @import("../goal/repository.zig").FsGoalRepository;
const FakeFs = @import("../fs/fs.zig").FakeFs;
const FakeProvider = @import("../provider/fake.zig").FakeProvider;

/// Test double that records every pushed `seq` and `state` (not just the last),
/// so A5 can prove seq is strictly increasing across rapid transitions.
const RecordingReporter = struct {
    alloc: Allocator,
    seqs: std.ArrayList(u64),
    states: std.ArrayList([]const u8),

    pub fn init(a: Allocator) !RecordingReporter {
        return .{ .alloc = a, .seqs = try std.ArrayList(u64).initCapacity(a, 0), .states = try std.ArrayList([]const u8).initCapacity(a, 0) };
    }
    pub fn toReporter(self: *RecordingReporter) state.HerdrReporter {
        return .{ .ctx = self, .vtable = &vtable };
    }
    const vtable = state.HerdrReporter.VTable{ .report = report };
    fn report(ctx: *anyopaque, a: Allocator, params: state.PaneReportParams) !void {
        const self: *RecordingReporter = @ptrCast(@alignCast(ctx));
        try self.seqs.append(a, params.seq);
        try self.states.append(a, try a.dupe(u8, params.state));
    }
    pub fn deinit(self: *RecordingReporter) void {
        for (self.states.items) |s| self.alloc.free(s);
        self.states.deinit(self.alloc);
        self.seqs.deinit(self.alloc);
    }
};

/// Drive a no-criterion goal to completion with a single content response.
fn runNoCriterion(alloc: Allocator, ex: *GoalExecutor) !Goal {
    const responses = [_]provider.ChatResponse{
        .{ .message = .{ .role = .assistant, .content = "done" } },
    };
    var fp = FakeProvider.init(&responses);
    ex.provider = fp.toProvider();
    var goal = try Goal.init(alloc, "do something", null, "sess1");
    try ex.run(&goal);
    return goal;
}

test "U14 executor publishes working at run start (screen marker before idle)" {
    const alloc = std.testing.allocator;
    var fake = FakeFs.init(alloc, "/wd");
    defer fake.deinit();
    var repo_impl = FsGoalRepository.init(fake.toFs(), ".ziki", "sess1");
    const repo = repo_impl.toRepository();
    const tools = [_]Tool{};

    var ex = GoalExecutor{
        .alloc = alloc, .provider = undefined, .tools = &tools,
        .repo = repo, .fs = fake.toFs(), .dir = ".ziki", .session_id = "sess1",
    };
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var hrep = state.FakeHerdrReporter.init(alloc);
    defer hrep.deinit();
    ex.publisher = state.StatePublisher.init(alloc, hrep.toReporter(), fbs.writer().any(), "pane-1", "goal-u14", "/wd");

    var goal = try runNoCriterion(alloc, &ex);
    defer goal.deinit(alloc);
    defer if (ex.report) |r| alloc.free(r);

    const written = buf[0..fbs.pos];
    const working_at = std.mem.indexOf(u8, written, "[ziki-state: working]") orelse @panic("no working marker");
    const idle_at = std.mem.indexOf(u8, written, "[ziki-state: idle]") orelse @panic("no idle marker");
    try std.testing.expect(working_at < idle_at);
    try std.testing.expectEqualStrings("idle", (hrep.last orelse @panic("no report")).state);
}

test "U15 executor publishes terminal idle on completion" {
    const alloc = std.testing.allocator;
    var fake = FakeFs.init(alloc, "/wd");
    defer fake.deinit();
    var repo_impl = FsGoalRepository.init(fake.toFs(), ".ziki", "sess1");
    const repo = repo_impl.toRepository();
    const tools = [_]Tool{};

    var ex = GoalExecutor{
        .alloc = alloc, .provider = undefined, .tools = &tools,
        .repo = repo, .fs = fake.toFs(), .dir = ".ziki", .session_id = "sess1",
    };
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var hrep = state.FakeHerdrReporter.init(alloc);
    defer hrep.deinit();
    ex.publisher = state.StatePublisher.init(alloc, hrep.toReporter(), fbs.writer().any(), "pane-1", "goal-u15", "/wd");

    var goal = try runNoCriterion(alloc, &ex);
    defer goal.deinit(alloc);
    defer if (ex.report) |r| alloc.free(r);

    try std.testing.expect(goal.status == .completed);
    const last = hrep.last orelse @panic("no report");
    try std.testing.expectEqualStrings("idle", last.state);
    try std.testing.expectEqual(@as(?[]const u8, null), last.message);
}

test "U16 executor publishes terminal idle on abort (turn budget exceeded)" {
    const alloc = std.testing.allocator;
    var fake = FakeFs.init(alloc, "/wd");
    defer fake.deinit();
    var repo_impl = FsGoalRepository.init(fake.toFs(), ".ziki", "sess1");
    const repo = repo_impl.toRepository();
    const tools = [_]Tool{};

    var ex = GoalExecutor{
        .alloc = alloc, .provider = undefined, .tools = &tools,
        .repo = repo, .fs = fake.toFs(), .dir = ".ziki", .session_id = "sess1",
    };
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var hrep = state.FakeHerdrReporter.init(alloc);
    defer hrep.deinit();
    ex.publisher = state.StatePublisher.init(alloc, hrep.toReporter(), fbs.writer().any(), "pane-1", "goal-u16", "/wd");

    // Zero-turn budget forces an abort on the first loop iteration.
    var goal = try Goal.init(alloc, "do something", null, "sess1");
    defer goal.deinit(alloc);
    goal.budgets.max_turns = 0;
    try ex.run(&goal);
    defer if (ex.report) |r| alloc.free(r);

    try std.testing.expect(goal.status == .aborted);
    const last = hrep.last orelse @panic("no report");
    try std.testing.expectEqualStrings("idle", last.state);
    // Working was announced at start, then idle on abort — no stale working.
    const written = buf[0..fbs.pos];
    try std.testing.expect(std.mem.indexOf(u8, written, "[ziki-state: working]") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "[ziki-state: idle]") != null);
}

test "U17 executor publishes blocked with a message" {
    const alloc = std.testing.allocator;
    var fake = FakeFs.init(alloc, "/wd");
    defer fake.deinit();
    var repo_impl = FsGoalRepository.init(fake.toFs(), ".ziki", "sess1");
    const repo = repo_impl.toRepository();
    const tools = [_]Tool{};

    var ex = GoalExecutor{
        .alloc = alloc, .provider = undefined, .tools = &tools,
        .repo = repo, .fs = fake.toFs(), .dir = ".ziki", .session_id = "sess1",
    };
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var hrep = state.FakeHerdrReporter.init(alloc);
    defer hrep.deinit();
    ex.publisher = state.StatePublisher.init(alloc, hrep.toReporter(), fbs.writer().any(), "pane-1", "goal-u17", "/wd");

    // Criterion never satisfied: three "NO" verifications -> blocked.
    const responses = [_]provider.ChatResponse{
        .{ .message = .{ .role = .assistant, .content = "NO" } },
        .{ .message = .{ .role = .assistant, .content = "NO" } },
        .{ .message = .{ .role = .assistant, .content = "NO" } },
    };
    var fp = FakeProvider.init(&responses);
    ex.provider = fp.toProvider();
    var goal = try Goal.init(alloc, "do something", "it is done", "sess1");
    defer goal.deinit(alloc);
    try ex.run(&goal);
    defer if (ex.report) |r| alloc.free(r);

    try std.testing.expect(goal.status == .blocked);
    const last = hrep.last orelse @panic("no report");
    try std.testing.expectEqualStrings("blocked", last.state);
    try std.testing.expect(last.message != null);
    const written = buf[0..fbs.pos];
    try std.testing.expect(std.mem.indexOf(u8, written, "[ziki-state: blocked]") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "[ziki-state: working]") != null);
}

test "U18 executor with null publisher runs unchanged (no publish attempted)" {
    const alloc = std.testing.allocator;
    var fake = FakeFs.init(alloc, "/wd");
    defer fake.deinit();
    var repo_impl = FsGoalRepository.init(fake.toFs(), ".ziki", "sess1");
    const repo = repo_impl.toRepository();
    const tools = [_]Tool{};

    // No `publisher` field set -> must behave exactly as the pre-011 executor.
    var ex = GoalExecutor{
        .alloc = alloc, .provider = undefined, .tools = &tools,
        .repo = repo, .fs = fake.toFs(), .dir = ".ziki", .session_id = "sess1",
    };
    var goal = try runNoCriterion(alloc, &ex);
    defer goal.deinit(alloc);
    defer if (ex.report) |r| alloc.free(r);
    try std.testing.expect(goal.status == .completed);
}

test "A1 mid-goal push carries full PaneReportParams + working marker/OSC (FR-002)" {
    const alloc = std.testing.allocator;
    var fake = FakeFs.init(alloc, "/wd");
    defer fake.deinit();
    var repo_impl = FsGoalRepository.init(fake.toFs(), ".ziki", "sess1");
    const repo = repo_impl.toRepository();
    var wt_impl = WriteTool.init(fake.toFs());
    const tools = [_]Tool{wt_impl.toTool()};

    var ex = GoalExecutor{
        .alloc = alloc, .provider = undefined, .tools = &tools,
        .repo = repo, .fs = fake.toFs(), .dir = ".ziki", .session_id = "sess1",
    };
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var hrep = state.FakeHerdrReporter.init(alloc);
    defer hrep.deinit();
    ex.publisher = state.StatePublisher.init(alloc, hrep.toReporter(), fbs.writer().any(), "pane-a1", "goal-a1", "/wd/.ziki");

    // Write a file, then finish -> working(start) then idle(end).
    const tcs = [_]provider.ToolCall{.{ .id = "c1", .name = "write_file", .arguments_json = "{\"path\":\"hello.txt\",\"data\":\"hi\"}" }};
    const responses = [_]provider.ChatResponse{
        .{ .message = .{ .role = .assistant, .content = "", .tool_calls = &tcs }, .finish_reason = .tool_calls },
        .{ .message = .{ .role = .assistant, .content = "done" } },
    };
    var fp = FakeProvider.init(&responses);
    ex.provider = fp.toProvider();
    var goal = try Goal.init(alloc, "create hello.txt", null, "sess1");
    defer goal.deinit(alloc);
    try ex.run(&goal);
    defer if (ex.report) |r| alloc.free(r);

    try std.testing.expect(goal.status == .completed);
    // The push params are constant across every publish; asserting them on the
    // last (idle) push proves the working push carried the same full contract.
    const last = hrep.last orelse @panic("no report");
    try std.testing.expectEqualStrings("pane-a1", last.pane_id);
    try std.testing.expectEqualStrings("herdr:ziki", last.source);
    try std.testing.expectEqualStrings("ziki", last.agent);
    try std.testing.expectEqualStrings("goal-a1", last.agent_session_id);
    try std.testing.expectEqualStrings("/wd/.ziki", last.agent_session_path);
    const written = buf[0..fbs.pos];
    try std.testing.expect(std.mem.indexOf(u8, written, "[ziki-state: working]") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "ziki:working") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "[ziki-state: idle]") != null);
}

test "A2 blocked push carries message + blocked marker/OSC (FR-006)" {
    const alloc = std.testing.allocator;
    var fake = FakeFs.init(alloc, "/wd");
    defer fake.deinit();
    var repo_impl = FsGoalRepository.init(fake.toFs(), ".ziki", "sess1");
    const repo = repo_impl.toRepository();
    const tools = [_]Tool{};

    var ex = GoalExecutor{
        .alloc = alloc, .provider = undefined, .tools = &tools,
        .repo = repo, .fs = fake.toFs(), .dir = ".ziki", .session_id = "sess1",
    };
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var hrep = state.FakeHerdrReporter.init(alloc);
    defer hrep.deinit();
    ex.publisher = state.StatePublisher.init(alloc, hrep.toReporter(), fbs.writer().any(), "pane-a2", "goal-a2", "/wd/.ziki");

    const responses = [_]provider.ChatResponse{
        .{ .message = .{ .role = .assistant, .content = "NO" } },
        .{ .message = .{ .role = .assistant, .content = "NO" } },
        .{ .message = .{ .role = .assistant, .content = "NO" } },
    };
    var fp = FakeProvider.init(&responses);
    ex.provider = fp.toProvider();
    var goal = try Goal.init(alloc, "do something", "it is done", "sess1");
    defer goal.deinit(alloc);
    try ex.run(&goal);
    defer if (ex.report) |r| alloc.free(r);

    const last = hrep.last orelse @panic("no report");
    try std.testing.expectEqualStrings("blocked", last.state);
    try std.testing.expect(last.message != null);
    try std.testing.expectEqualStrings("herdr:ziki", last.source);
    try std.testing.expectEqualStrings("ziki", last.agent);
    const written = buf[0..fbs.pos];
    try std.testing.expect(std.mem.indexOf(u8, written, "[ziki-state: blocked]") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "ziki:blocked") != null);
}

test "A3 terminal idle push leaves no stale working state (FR-006)" {
    const alloc = std.testing.allocator;
    var fake = FakeFs.init(alloc, "/wd");
    defer fake.deinit();
    var repo_impl = FsGoalRepository.init(fake.toFs(), ".ziki", "sess1");
    const repo = repo_impl.toRepository();
    const tools = [_]Tool{};

    var ex = GoalExecutor{
        .alloc = alloc, .provider = undefined, .tools = &tools,
        .repo = repo, .fs = fake.toFs(), .dir = ".ziki", .session_id = "sess1",
    };
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var hrep = state.FakeHerdrReporter.init(alloc);
    defer hrep.deinit();
    ex.publisher = state.StatePublisher.init(alloc, hrep.toReporter(), fbs.writer().any(), "pane-a3", "goal-a3", "/wd/.ziki");

    var goal = try runNoCriterion(alloc, &ex);
    defer goal.deinit(alloc);
    defer if (ex.report) |r| alloc.free(r);

    // The final published state must be idle (no stale working).
    const last = hrep.last orelse @panic("no report");
    try std.testing.expectEqualStrings("idle", last.state);
    const written = buf[0..fbs.pos];
    const last_working = lastIndexOf(written, "[ziki-state: working]");
    const last_idle = lastIndexOf(written, "[ziki-state: idle]");
    try std.testing.expect(last_idle > last_working);
}

test "A4 degraded mode (null reporter) still emits markers/OSC, no crash (FR-008)" {
    const alloc = std.testing.allocator;
    var fake = FakeFs.init(alloc, "/wd");
    defer fake.deinit();
    var repo_impl = FsGoalRepository.init(fake.toFs(), ".ziki", "sess1");
    const repo = repo_impl.toRepository();
    const tools = [_]Tool{};

    var ex = GoalExecutor{
        .alloc = alloc, .provider = undefined, .tools = &tools,
        .repo = repo, .fs = fake.toFs(), .dir = ".ziki", .session_id = "sess1",
    };
    // reporter = null: no push path, but markers + OSC must still emit.
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    ex.publisher = state.StatePublisher.init(alloc, null, fbs.writer().any(), "pane-a4", "goal-a4", "/wd/.ziki");

    var goal = try runNoCriterion(alloc, &ex);
    defer goal.deinit(alloc);
    defer if (ex.report) |r| alloc.free(r);

    try std.testing.expect(goal.status == .completed);
    const written = buf[0..fbs.pos];
    try std.testing.expect(std.mem.indexOf(u8, written, "[ziki-state: working]") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "ziki:working") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "[ziki-state: idle]") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "ziki:idle") != null);
}

test "A5 seq is strictly increasing across rapid transitions (no stale report wins)" {
    const alloc = std.testing.allocator;
    var fake = FakeFs.init(alloc, "/wd");
    defer fake.deinit();
    var repo_impl = FsGoalRepository.init(fake.toFs(), ".ziki", "sess1");
    const repo = repo_impl.toRepository();
    const tools = [_]Tool{};

    var ex = GoalExecutor{
        .alloc = alloc, .provider = undefined, .tools = &tools,
        .repo = repo, .fs = fake.toFs(), .dir = ".ziki", .session_id = "sess1",
    };
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var rec = try RecordingReporter.init(alloc);
    defer rec.deinit();
    ex.publisher = state.StatePublisher.init(alloc, rec.toReporter(), fbs.writer().any(), "pane-a5", "goal-a5", "/wd/.ziki");

    const responses = [_]provider.ChatResponse{
        .{ .message = .{ .role = .assistant, .content = "NO" } },
        .{ .message = .{ .role = .assistant, .content = "NO" } },
        .{ .message = .{ .role = .assistant, .content = "NO" } },
    };
    var fp = FakeProvider.init(&responses);
    ex.provider = fp.toProvider();
    var goal = try Goal.init(alloc, "do something", "it is done", "sess1");
    defer goal.deinit(alloc);
    try ex.run(&goal);
    defer if (ex.report) |r| alloc.free(r);

    try std.testing.expect(goal.status == .blocked);
    try std.testing.expect(rec.seqs.items.len >= 2);
    var prev: u64 = 0;
    for (rec.seqs.items) |s| {
        try std.testing.expect(s > prev);
        prev = s;
    }
    try std.testing.expectEqualStrings("working", rec.states.items[0]);
    try std.testing.expectEqualStrings("blocked", rec.states.items[rec.states.items.len - 1]);
}

/// Last index of `needle` in `hay`, or 0 if absent (treated as "before start").
fn lastIndexOf(hay: []const u8, needle: []const u8) usize {
    if (std.mem.lastIndexOf(u8, hay, needle)) |i| return i;
    return 0;
}
