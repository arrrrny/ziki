const std = @import("std");
const Allocator = std.mem.Allocator;
const state = @import("state.zig");
const provider = @import("../provider/provider.zig");
const Tool = @import("../tool/tool.zig").Tool;
const ToolResult = @import("../tool/tool.zig").ToolResult;
const Goal = @import("../goal/goal.zig").Goal;
const GoalRepository = @import("../goal/repository.zig").GoalRepository;
const Fs = @import("../fs/fs.zig").Fs;

/// Drives an autonomous goal loop (FR-002/003/008). Depends only on injected
/// interfaces (DIP): Provider, Tool[], GoalRepository, Fs.
const IntentionalMap = std.StringHashMap(bool);

pub const GoalExecutor = struct {
    alloc: Allocator,
    provider: provider.Provider,
    tools: []const Tool,
    repo: GoalRepository,
    fs: Fs,
    dir: []const u8,
    session_id: []const u8,
    verbose: bool = false,
    /// When true (default), the executor reverts uncommitted drift the agent
    /// introduced this run but did not intentionally change, leaving the tree
    /// clean (FR-005). Disabled with `--no-clean`.
    clean_tree: bool = true,
    /// Files the agent intentionally wrote/edited this run (FR-005/FR-006).
    intentional: IntentionalMap = undefined,
    /// Paths already modified/untracked before the run started (FR-005 safety).
    pre_existing: IntentionalMap = undefined,
    /// Human-readable reasons something was skipped (FR-006).
    skipped: std.ArrayList(u8) = undefined,
    /// Final job report string (owned by `alloc`), available after `run`.
    report: ?[]const u8 = null,
    /// Optional Herdr state publisher (spec 011). When set, the executor emits
    /// Ziki's agent state at each lifecycle transition (working at start,
    /// blocked/idle at terminal). When null the loop behaves exactly as before
    /// (SC-005): no publication, no side effects (FR-008).
    publisher: ?state.StatePublisher = null,

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
                const res = try t.execute(a, tc.arguments_json);
                // FR-005/FR-006: remember files the agent intentionally changed.
                if (res.ok and (std.mem.eql(u8, tc.name, "write_file") or std.mem.eql(u8, tc.name, "edit_file"))) {
                    self.recordChange(a, tc.arguments_json);
                }
                return res;
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
        // FR-005/FR-006 bookkeeping, alive for the whole run and freed at the end.
        self.intentional = IntentionalMap.init(self.alloc);
        self.pre_existing = IntentionalMap.init(self.alloc);
        self.skipped = try std.ArrayList(u8).initCapacity(self.alloc, 0);
        defer self.deinitMaps();
        defer self.finalizeReport() catch {};

        // Snapshot the tree as it was before we started, so cleanup only reverts
        // drift this run introduced (never pre-existing user state).
        if (self.clean_tree) {
            self.snapshotPreExisting() catch {};
        }

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
        // FR-001/FR-002: announce `working` the moment the loop becomes active.
        if (self.publisher != null) {
            self.publisher.?.publish(.working, null);
        }
        while (goal.status == .active) {
            if (self.fs.exists(try self.stopPath(a))) {
                self.fs.remove(try self.stopPath(a)) catch {};
                goal.status = .aborted;
                if (self.publisher != null) {
            self.publisher.?.publish(.idle, "aborted by user");
                }
                try self.setProgress(goal, "aborted by user");
                try self.addSkip("job aborted by user");
                try self.repo.save(self.alloc, goal.*);
                return;
            }
            if (goal.used.turns >= goal.budgets.max_turns) {
                goal.status = .aborted;
                if (self.publisher != null) {
            self.publisher.?.publish(.idle, "aborted: turn budget exceeded");
                }
                try self.setProgress(goal, "aborted: turn budget exceeded");
                try self.addSkip("aborted: turn budget exceeded");
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
                    if (self.publisher != null) {
            self.publisher.?.publish(.idle, null);
                    }
                    try self.setProgress(goal, "completed: criterion satisfied");
                    try self.repo.save(self.alloc, goal.*);
                    return;
                }
                verify_attempts += 1;
                if (verify_attempts >= 3) {
                    goal.status = .blocked;
                    if (self.publisher != null) {
            self.publisher.?.publish(.blocked, "criterion not satisfied after retries");
                    }
                    try self.setProgress(goal, "could not satisfy criterion after retries");
                    try self.addSkip("completion criterion not satisfied after retries");
                    try self.repo.save(self.alloc, goal.*);
                    return;
                }
                continue;
            }

            goal.status = .completed;
            if (self.publisher != null) {
            self.publisher.?.publish(.idle, null);
            }
            try self.setProgress(goal, "completed");
            try self.repo.save(self.alloc, goal.*);
            return;
        }
    }

    /// Record a file the agent intentionally wrote/edited this run (FR-005/FR-006).
    /// Record a file the agent intentionally wrote/edited this run (FR-005/FR-006).
    fn recordChange(self: *GoalExecutor, a: Allocator, args_json: []const u8) void {
        const Args = struct { path: []const u8 };
        // `ignore_unknown_fields`: the tool JSON may carry fields we don't need
        // (e.g. `data` for write_file, `old`/`new` for edit_file).
        var parsed = std.json.parseFromSlice(Args, a, args_json, .{ .ignore_unknown_fields = true }) catch return;
        defer parsed.deinit();
        const owned = self.alloc.dupe(u8, parsed.value.path) catch return;
        self.intentional.put(owned, true) catch {
            self.alloc.free(owned);
        };
    }

    /// Append a human-readable reason something was skipped (FR-006).
    fn addSkip(self: *GoalExecutor, msg: []const u8) !void {
        try std.fmt.format(self.skipped.writer(self.alloc), "{s}\n", .{msg});
    }

    /// Snapshot paths already modified/untracked before the run (FR-005 safety).
    fn snapshotPreExisting(self: *GoalExecutor) !void {
        const out = try gitStatus(self.alloc, self.fs.cwd());
        defer self.alloc.free(out);
        var it = std.mem.splitScalar(u8, out, '\n');
        while (it.next()) |line| {
            const sp = gitLineStatusPath(line) orelse continue;
            const owned = try self.alloc.dupe(u8, sp.path);
            try self.pre_existing.put(owned, true);
        }
    }

    /// Build the FR-006 job report (changed / skipped / reverted) and store it.
    fn finalizeReport(self: *GoalExecutor) !void {
        var sb = try std.ArrayList(u8).initCapacity(self.alloc, 0);

        try sb.appendSlice(self.alloc, "changed:\n");
        if (self.intentional.count() == 0) {
            try sb.appendSlice(self.alloc, "  (none)\n");
        } else {
            var it = self.intentional.keyIterator();
            while (it.next()) |k| {
                try std.fmt.format(sb.writer(self.alloc), "  {s}\n", .{k.*});
            }
        }

        try sb.appendSlice(self.alloc, "skipped:\n");
        if (self.skipped.items.len == 0) {
            try sb.appendSlice(self.alloc, "  (none)\n");
        } else {
            var it = std.mem.splitScalar(u8, self.skipped.items, '\n');
            while (it.next()) |line| {
                if (line.len == 0) continue;
                try std.fmt.format(sb.writer(self.alloc), "  {s}\n", .{line});
            }
        }

        if (self.clean_tree) {
            const reverted = try revertIncidental(self.alloc, self.fs.cwd(), &self.intentional, &self.pre_existing);
            defer self.alloc.free(reverted);
            if (reverted.len > 0) {
                try sb.appendSlice(self.alloc, "reverted (incidental):\n");
                var it = std.mem.splitScalar(u8, reverted, '\n');
                while (it.next()) |line| {
                    if (line.len == 0) continue;
                    try std.fmt.format(sb.writer(self.alloc), "  {s}\n", .{line});
                }
            }
        }

        self.report = try sb.toOwnedSlice(self.alloc);
    }

    /// Free the per-run maps and the skipped buffer (keys are `alloc`-owned).
    fn deinitMaps(self: *GoalExecutor) void {
        var it = self.intentional.keyIterator();
        while (it.next()) |k| self.alloc.free(k.*);
        self.intentional.deinit();
        var it2 = self.pre_existing.keyIterator();
        while (it2.next()) |k| self.alloc.free(k.*);
        self.pre_existing.deinit();
        self.skipped.deinit(self.alloc);
    }
};

/// Spawn a command and capture its stdout, or return "" on any failure.
/// Used by the FR-005 tree-cleanup helpers; failures are non-fatal (the cleanup
/// is best-effort and must never crash the goal loop).
fn runCapture(alloc: Allocator, argv: []const []const u8) ![]u8 {
    var child = std.process.Child.init(argv, alloc);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return alloc.dupe(u8, "");
    const fd = child.stdout.?.handle;
    var out = try std.ArrayList(u8).initCapacity(alloc, 0);
    var tmp: [4096]u8 = undefined;
    while (true) {
        const n = std.posix.read(fd, &tmp) catch {
            out.deinit(alloc);
            _ = child.wait() catch unreachable;
            return alloc.dupe(u8, "");
        };
        if (n == 0) break;
        out.appendSlice(alloc, tmp[0..n]) catch {
            out.deinit(alloc);
            _ = child.wait() catch unreachable;
            return alloc.dupe(u8, "");
        };
    }
    _ = child.wait() catch unreachable;
    return out.toOwnedSlice(alloc);
}

/// `git status --porcelain` output for `cwd`, or "" if git is unavailable.
fn gitStatus(alloc: Allocator, cwd: []const u8) ![]u8 {
    const argv = [_][]const u8{ "git", "-C", cwd, "status", "--porcelain" };
    return runCapture(alloc, &argv);
}

/// Split one porcelain line into its status code and path (or null if empty).
fn gitLineStatusPath(line: []const u8) ?struct { status: []const u8, path: []const u8 } {
    if (line.len < 3) return null;
    const status = line[0..2];
    const path = std.mem.trim(u8, line[3..], " ");
    if (path.len == 0) return null;
    return .{ .status = status, .path = path };
}

/// Parse `git status --porcelain` output into a list of changed paths.
fn parseStatusPaths(alloc: Allocator, out: []const u8) ![][]const u8 {
    var list = try std.ArrayList([]const u8).initCapacity(alloc, 0);
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |line| {
        const sp = gitLineStatusPath(line) orelse continue;
        try list.append(alloc, try alloc.dupe(u8, sp.path));
    }
    return list.toOwnedSlice(alloc);
}

/// Revert uncommitted drift that is not in `intentional` and not `pre_existing`
/// (FR-005): tracked files revert to HEAD, untracked/staged-new files are
/// removed. Returns a newline-separated list of reverted paths (owned by `alloc`).
fn revertIncidental(alloc: Allocator, cwd: []const u8, intentional: *const IntentionalMap, pre_existing: *const IntentionalMap) ![]const u8 {
    const out = try gitStatus(alloc, cwd);
    defer alloc.free(out);
    var reverted = try std.ArrayList(u8).initCapacity(alloc, 0);
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |line| {
        const sp = gitLineStatusPath(line) orelse continue;
        if (intentional.contains(sp.path)) continue;
        if (pre_existing.contains(sp.path)) continue;
        if (std.mem.eql(u8, sp.status, "??")) {
            const argv = [_][]const u8{ "git", "-C", cwd, "clean", "-fd", "--", sp.path };
            if (runCapture(alloc, &argv)) |cap| alloc.free(cap) else |_| {}
        } else if (std.mem.eql(u8, sp.status, "A ")) {
            const unstage = [_][]const u8{ "git", "-C", cwd, "rm", "--cached", "--force", "--", sp.path };
            if (runCapture(alloc, &unstage)) |cap| alloc.free(cap) else |_| {}
            const rm = [_][]const u8{ "rm", "-f", sp.path };
            if (runCapture(alloc, &rm)) |cap| alloc.free(cap) else |_| {}
        } else {
            const argv = [_][]const u8{ "git", "-C", cwd, "checkout", "HEAD", "--", sp.path };
            if (runCapture(alloc, &argv)) |cap| alloc.free(cap) else |_| {}
        }
        try std.fmt.format(reverted.writer(alloc), "{s}\n", .{sp.path});
    }
    return reverted.toOwnedSlice(alloc);
}

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
    defer if (ex.report) |r| alloc.free(r);

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
    defer if (ex.report) |r| alloc.free(r);

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
    defer if (ex.report) |r| alloc.free(r);

    try std.testing.expect(goal.status == .completed);
}

/// Test/cleanup helper: run `git -C <cwd> <args>`, ignoring output (non-fatal).
fn runGit(alloc: Allocator, cwd: []const u8, args: []const []const u8) !void {
    var argv = try std.ArrayList([]const u8).initCapacity(alloc, 0);
    defer argv.deinit(alloc);
    try argv.appendSlice(alloc, &.{ "git", "-C", cwd });
    try argv.appendSlice(alloc, args);
    if (runCapture(alloc, argv.items)) |cap| alloc.free(cap) else |_| {}
}

test "parseStatusPaths extracts changed paths from porcelain" {
    const alloc = std.testing.allocator;
    const out =
        \\ M src/a.zig
        \\?? b.txt
        \\A  c.zig
        \\R  old.zig -> new.zig
    ;
    const paths = try parseStatusPaths(alloc, out);
    defer {
        for (paths) |p| alloc.free(p);
        alloc.free(paths);
    }
    try std.testing.expect(paths.len == 4);
    try std.testing.expect(std.mem.indexOf(u8, paths[0], "src/a.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, paths[1], "b.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, paths[2], "c.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, paths[3], "old.zig") != null);
}

test "revertIncidental reverts only drift, not pre-existing or intentional" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    const dir = tmp.dir;
    const cwd = try dir.realpathAlloc(alloc, ".");
    defer alloc.free(cwd);
    defer tmp.cleanup();

    // init repo + initial commit of a tracked file
    try runGit(alloc, cwd, &.{ "init", "-q" });
    try runGit(alloc, cwd, &.{ "config", "user.email", "test@example.com" });
    try runGit(alloc, cwd, &.{ "config", "user.name", "test" });
    try dir.writeFile(.{ .sub_path = "tracked.txt", .data = "original" });
    try runGit(alloc, cwd, &.{ "add", "tracked.txt" });
    try runGit(alloc, cwd, &.{ "commit", "-q", "-m", "init" });

    // a pre-existing untracked file the user already had (must survive cleanup)
    try dir.writeFile(.{ .sub_path = "preexisting.txt", .data = "mine" });
    // drift introduced during the run: a modified tracked file + a stray untracked file
    try dir.writeFile(.{ .sub_path = "tracked.txt", .data = "DRIFT" });
    try dir.writeFile(.{ .sub_path = "stray.txt", .data = "oops" });

    var pre = IntentionalMap.init(alloc);
    defer {
        var it = pre.keyIterator();
        while (it.next()) |k| alloc.free(k.*);
        pre.deinit();
    }
    const pre_path = try alloc.dupe(u8, "preexisting.txt");
    try pre.put(pre_path, true);

    var intentional = IntentionalMap.init(alloc);
    defer {
        var it = intentional.keyIterator();
        while (it.next()) |k| alloc.free(k.*);
        intentional.deinit();
    }

    const reverted = try revertIncidental(alloc, cwd, &intentional, &pre);
    defer alloc.free(reverted);
    const st = try gitStatus(alloc, cwd);
    defer alloc.free(st);
    try std.testing.expect(std.mem.indexOf(u8, reverted, "stray.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, reverted, "tracked.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, reverted, "preexisting.txt") == null);

    // On disk: tracked reverted to original, stray gone, preexisting kept.
    const t = try dir.readFileAlloc(alloc, "tracked.txt", 64);
    defer alloc.free(t);
    try std.testing.expectEqualStrings("original", t);
    // stray.txt was incidental untracked drift and must be removed by cleanup.
    try std.testing.expect(dir.access("stray.txt", .{}) == error.FileNotFound);
    const p = try dir.readFileAlloc(alloc, "preexisting.txt", 64);
    defer alloc.free(p);
    try std.testing.expectEqualStrings("mine", p);
}

test "GoalExecutor records a job report of changed files (FR-006)" {
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
    var goal = try @import("../goal/goal.zig").Goal.init(alloc, "create hello.txt", null, "sess1");
    defer goal.deinit(alloc);
    try ex.run(&goal);

    try std.testing.expect(goal.status == .completed);
    try std.testing.expect(ex.report != null);
    const r = ex.report.?;
    defer alloc.free(r);
    try std.testing.expect(std.mem.indexOf(u8, r, "changed:") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "hello.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "skipped:\n  (none)") != null);
}
