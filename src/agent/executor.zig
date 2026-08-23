const std = @import("std");
const Allocator = std.mem.Allocator;
const provider = @import("../provider/provider.zig");
const Tool = @import("../tool/tool.zig").Tool;
const ToolResult = @import("../tool/tool.zig").ToolResult;
const Goal = @import("../goal/goal.zig").Goal;
const GoalRepository = @import("../goal/repository.zig").GoalRepository;
const Fs = @import("../fs/fs.zig").Fs;

/// Drives an autonomous goal loop (FR-002/003/008). Depends only on injected
/// interfaces (DIP): Provider, Tool[], GoalRepository, Fs.
pub const GoalExecutor = struct {
    alloc: Allocator,
    provider: provider.Provider,
    tools: []const Tool,
    repo: GoalRepository,
    fs: Fs,
    dir: []const u8,
    session_id: []const u8,
    verbose: bool = false,

    /// Print a diagnostic line to stdout (only when verbose). Used so an
    /// autonomous run is observable instead of appearing to "do nothing".
    fn logLine(alloc: Allocator, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.allocPrint(alloc, fmt ++ "\n", args) catch return;
        defer alloc.free(s);
        std.fs.File.stdout().writeAll(s) catch {};
    }

    fn stopPath(self: *GoalExecutor, a: Allocator) ![]u8 {
        return std.fmt.allocPrint(a, "{s}/stop.{s}", .{ self.dir, self.session_id });
    }

    /// Owns `goal.progress` as a heap slice: frees the previous value before
    /// storing the new one so the executor never leaks between turns.
    fn setProgress(self: *GoalExecutor, goal: *Goal, p: []const u8) !void {
        self.alloc.free(goal.progress);
        goal.progress = try self.alloc.dupe(u8, p);
    }

    fn systemPrompt(self: *GoalExecutor) ![]u8 {
        var sb = try std.ArrayList(u8).initCapacity(self.alloc, 0);
        try sb.writer(self.alloc).writeAll(
            \\You are an autonomous coding agent. Use the provided tools to pursue the user's goal.
            \\Call one tool at a time. When the goal is achieved, reply with a final message and no tool calls.
            \\
        );
        for (self.tools) |t| {
            const s = t.schema();
            try std.fmt.format(sb.writer(self.alloc), "Tool {s}: {s}\n", .{ s.name, s.description });
        }
        return sb.toOwnedSlice(self.alloc);
    }

    fn userPrompt(self: *GoalExecutor, goal: *Goal) ![]u8 {
        if (goal.criterion) |c| {
            return std.fmt.allocPrint(self.alloc, "Goal: {s}\nCompletion criterion: {s}", .{ goal.objective, c });
        }
        return std.fmt.allocPrint(self.alloc, "Goal: {s}", .{goal.objective});
    }

    fn toolSpecs(self: *GoalExecutor, a: Allocator) ![]const provider.ToolSpec {
        const specs = try a.alloc(provider.ToolSpec, self.tools.len);
        for (self.tools, 0..) |t, i| {
            specs[i] = t.schema();
        }
        return specs;
    }

    fn dispatch(self: *GoalExecutor, a: Allocator, tc: provider.ToolCall) !ToolResult {
        for (self.tools) |t| {
            if (std.mem.eql(u8, t.name(), tc.name)) {
                return try t.execute(a, tc.arguments_json);
            }
        }
        return ToolResult{ .ok = false, .error_message = try std.fmt.allocPrint(a, "unknown tool: {s}", .{tc.name}) };
    }

    fn verify(self: *GoalExecutor, a: Allocator, messages: *std.ArrayList(provider.ChatMessage), criterion: []const u8) !bool {
        try messages.append(a, .{ .role = .user, .content = try a.dupe(u8, try std.fmt.allocPrint(a, "Criterion: {s}\nIs it satisfied? Reply with exactly YES or NO.", .{criterion})) });
        const resp = try self.completeRetry(a, .{ .messages = messages.items, .tools = &[0]provider.ToolSpec{} });
        const content = resp.message.content;
        if (self.verbose) logLine(self.alloc, "verbose: verify -> {s}", .{content});
        try messages.append(a, .{ .role = .assistant, .content = try a.dupe(u8, content) });
        const upper = try std.ascii.allocUpperString(a, content);
        const yes = std.mem.indexOf(u8, upper, "YES") != null;
        a.free(upper);
        return yes;
    }

    /// Complete a request, retrying transient provider failures. Real HTTP
    /// providers are occasionally unavailable (5xx, network blips); a bounded
    /// retry keeps an otherwise-good goal loop from dying on a single bad turn.
    fn completeRetry(self: *GoalExecutor, a: Allocator, req: provider.CompletionRequest) !provider.ChatResponse {
        const max_attempts: u32 = 3;
        var attempt: u32 = 0;
        while (attempt < max_attempts) : (attempt += 1) {
            return self.provider.complete(a, req) catch |e| {
                if (attempt + 1 == max_attempts) return e;
                std.Thread.sleep(200 * std.time.ns_per_ms);
                continue;
            };
        }
        unreachable;
    }

    /// Run the goal to a terminal state (completed / blocked / aborted).
    pub fn run(self: *GoalExecutor, goal: *Goal) !void {
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const a = arena.allocator();

        var messages = try std.ArrayList(provider.ChatMessage).initCapacity(a, 0);
        const sp = try self.systemPrompt();
        defer self.alloc.free(sp);
        try messages.append(a, .{ .role = .system, .content = try a.dupe(u8, sp) });
        const up = try self.userPrompt(goal);
        defer self.alloc.free(up);
        try messages.append(a, .{ .role = .user, .content = try a.dupe(u8, up) });

        var verify_attempts: u32 = 0;
        while (goal.status == .active) {
            if (self.fs.exists(try self.stopPath(a))) {
                self.fs.remove(try self.stopPath(a)) catch {};
                goal.status = .aborted;
                try self.setProgress(goal, "aborted by user");
                try self.repo.save(self.alloc, goal.*);
                return;
            }
            if (goal.used.turns >= goal.budgets.max_turns) {
                goal.status = .aborted;
                try self.setProgress(goal, "aborted: turn budget exceeded");
                try self.repo.save(self.alloc, goal.*);
                return;
            }
            goal.used.turns += 1;

            if (self.verbose) logLine(self.alloc, "verbose: turn {d}: requesting model ({d} msgs)", .{ goal.used.turns, messages.items.len });

            const specs = try self.toolSpecs(a);
            const resp = try self.completeRetry(a, .{ .messages = messages.items, .tools = specs });
            try messages.append(a, resp.message);

            if (self.verbose) {
                if (resp.message.tool_calls) |tcs| {
                    for (tcs) |tc| logLine(self.alloc, "verbose: tool_call {s} {s}", .{ tc.name, tc.arguments_json });
                } else {
                    logLine(self.alloc, "verbose: model: {s}", .{resp.message.content});
                }
            }

            if (resp.message.tool_calls) |tcs| {
                for (tcs) |tc| {
                    const res = try self.dispatch(a, tc);
                    if (self.verbose) logLine(self.alloc, "verbose: tool_result[{s}]: {s}", .{ tc.name, res.output });
                    try messages.append(a, .{
                        .role = .tool,
                        .content = try a.dupe(u8, res.output),
                        .tool_call_id = try a.dupe(u8, tc.id),
                    });
                }
                const p = try std.fmt.allocPrint(self.alloc, "executed {d} tool call(s)", .{tcs.len});
                self.alloc.free(goal.progress);
                goal.progress = p;
                try self.repo.save(self.alloc, goal.*);
                continue;
            }

            if (goal.criterion) |crit| {
                const satisfied = try self.verify(a, &messages, crit);
                if (satisfied) {
                    goal.status = .completed;
                    try self.setProgress(goal, "completed: criterion satisfied");
                    try self.repo.save(self.alloc, goal.*);
                    return;
                }
                verify_attempts += 1;
                if (verify_attempts >= 3) {
                    goal.status = .blocked;
                    try self.setProgress(goal, "could not satisfy criterion after retries");
                    try self.repo.save(self.alloc, goal.*);
                    return;
                }
                continue;
            }

            goal.status = .completed;
            try self.setProgress(goal, "completed");
            try self.repo.save(self.alloc, goal.*);
            return;
        }
    }
};

test "GoalExecutor drives a goal to completion (FakeProvider + FakeFs)" {
    const alloc = std.testing.allocator;

    const FakeFs = @import("../fs/fs.zig").FakeFs;
    const WriteTool = @import("../tool/write.zig").WriteTool;
    const FsGoalRepository = @import("../goal/repository.zig").FsGoalRepository;

    var fake = FakeFs.init(alloc, "/wd");
    defer fake.deinit();

    const tcs = [_]provider.ToolCall{.{ .id = "c1", .name = "write_file", .arguments_json = "{\"path\":\"hello.txt\",\"data\":\"hi\"}" }};
    const responses = [_]provider.ChatResponse{
        .{ .message = .{ .role = .assistant, .content = "", .tool_calls = &tcs }, .finish_reason = .tool_calls },
        .{ .message = .{ .role = .assistant, .content = "done" } },
    };
    var fp = @import("../provider/fake.zig").FakeProvider.init(&responses);

    var wt_impl = WriteTool.init(fake.toFs());
    const wt = wt_impl.toTool();
    const tools = [_]Tool{wt};
    var repo_impl = FsGoalRepository.init(fake.toFs(), ".ziki", "sess1");
    const repo = repo_impl.toRepository();

    var ex = GoalExecutor{
        .alloc = alloc,
        .provider = fp.toProvider(),
        .tools = &tools,
        .repo = repo,
        .fs = fake.toFs(),
        .dir = ".ziki",
        .session_id = "sess1",
    };
    var goal = try @import("../goal/goal.zig").Goal.init(alloc, "create hello.txt containing hi", null, "sess1");
    defer goal.deinit(alloc);
    try ex.run(&goal);

    try std.testing.expect(goal.status == .completed);
    const content = try fake.readFile(alloc, "hello.txt");
    defer alloc.free(content);
    try std.testing.expectEqualStrings("hi", content);
}

test "GoalExecutor honours an explicit completion criterion" {
    const alloc = std.testing.allocator;

    const FakeFs = @import("../fs/fs.zig").FakeFs;
    const WriteTool = @import("../tool/write.zig").WriteTool;
    const FsGoalRepository = @import("../goal/repository.zig").FsGoalRepository;

    var fake = FakeFs.init(alloc, "/wd");
    defer fake.deinit();

    const tcs = [_]provider.ToolCall{.{ .id = "c1", .name = "write_file", .arguments_json = "{\"path\":\"hello.txt\",\"data\":\"hi\"}" }};
    // turn1: write tool call; turn2: stop; turn3 (verify): YES -> completed.
    const responses = [_]provider.ChatResponse{
        .{ .message = .{ .role = .assistant, .content = "", .tool_calls = &tcs }, .finish_reason = .tool_calls },
        .{ .message = .{ .role = .assistant, .content = "stopped" } },
        .{ .message = .{ .role = .assistant, .content = "YES the file exists" } },
    };
    var fp = @import("../provider/fake.zig").FakeProvider.init(&responses);

    var wt_impl = WriteTool.init(fake.toFs());
    const wt = wt_impl.toTool();
    const tools = [_]Tool{wt};
    var repo_impl = FsGoalRepository.init(fake.toFs(), ".ziki", "sess1");
    const repo = repo_impl.toRepository();

    var ex = GoalExecutor{
        .alloc = alloc,
        .provider = fp.toProvider(),
        .tools = &tools,
        .repo = repo,
        .fs = fake.toFs(),
        .dir = ".ziki",
        .session_id = "sess1",
    };
    var goal = try @import("../goal/goal.zig").Goal.init(alloc, "create hello.txt", "hello.txt exists with hi", "sess1");
    defer goal.deinit(alloc);
    try ex.run(&goal);

    try std.testing.expect(goal.status == .completed);
}

test "GoalExecutor retries transient provider errors and still completes" {
    const alloc = std.testing.allocator;

    const FakeFs = @import("../fs/fs.zig").FakeFs;
    const FsGoalRepository = @import("../goal/repository.zig").FsGoalRepository;
    const FlakyProvider = @import("../provider/fake.zig").FlakyProvider;

    var fake = FakeFs.init(alloc, "/wd");
    defer fake.deinit();

    // Every provider turn fails twice then succeeds; the executor must retry.
    // A no-criterion goal completes on the first successful (retried) turn.
    const ok = provider.ChatResponse{ .message = .{ .role = .assistant, .content = "done" } };
    var flaky = FlakyProvider.init(2, ok);
    const fp = flaky.toProvider();

    const tools = [_]Tool{};
    var repo_impl = FsGoalRepository.init(fake.toFs(), ".ziki", "sess1");
    const repo = repo_impl.toRepository();

    var ex = GoalExecutor{
        .alloc = alloc,
        .provider = fp,
        .tools = &tools,
        .repo = repo,
        .fs = fake.toFs(),
        .dir = ".ziki",
        .session_id = "sess1",
    };
    var goal = try @import("../goal/goal.zig").Goal.init(alloc, "do something", null, "sess1");
    defer goal.deinit(alloc);
    try ex.run(&goal);

    try std.testing.expect(goal.status == .completed);
}
