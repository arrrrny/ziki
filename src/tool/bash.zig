const std = @import("std");
const Allocator = std.mem.Allocator;
const Tool = @import("tool.zig").Tool;
const ToolResult = @import("tool.zig").ToolResult;
const ToolSpec = @import("../provider/provider.zig").ToolSpec;
const Fs = @import("../fs/fs.zig").Fs;

/// Run a shell command in the working directory and capture stdout/stderr +
/// exit code. A command that does not exit within `timeout_seconds` is killed
/// so a hung command (watch-mode test runner, interactive prompt, build
/// waiting on input) can never stall the autonomous goal loop (FR-008 edge
/// case: graceful termination).
///
/// Capture uses a single-threaded `poll()` loop (no reader threads). This
/// avoids a process-reaping deadlock that occurred when two reader threads
/// raced on the child's stdout/stderr pipes while the main thread blocked in
/// `child.wait()`, which left the goal loop silently hanging on every command.
pub const BashTool = struct {
    fs: Fs,
    /// When false (default), `git push` to a remote is refused (FR-002).
    allow_push: bool = false,
    /// Per-command time budget in seconds; `no_timeout` disables killing (FR-003).
    timeout_seconds: u64 = 600,
    /// Set when an unauthorized push was blocked this run (read by the report).
    push_blocked: bool = false,
    /// Set when an authorized push succeeded this run (read by the report).
    push_occurred: bool = false,

    pub fn init(fs: Fs, allow_push: bool, timeout_seconds: u64) BashTool {
        return .{ .fs = fs, .allow_push = allow_push, .timeout_seconds = timeout_seconds };
    }
    pub fn toTool(self: *BashTool) Tool {
        return .{ .ctx = self, .vtable = &vtable };
    }
    const vtable = Tool.VTable{ .execute = execute, .schema = schema, .name = name };

    fn name(_: *anyopaque) []const u8 {
        return "run_command";
    }
    fn schema(_: *anyopaque) ToolSpec {
        return .{
            .name = "run_command",
            .description = "Execute a shell command and return its combined output and exit code. Commands that hang are killed after a timeout.",
            .parameters_json_schema =
                \\{"type":"object","properties":{"command":{"type":"string"}},"required":["command"]}
            ,
        };
    }

    const max_output_bytes: usize = 2 * 1024 * 1024;

    /// Sentinel budget meaning "never time out". Used by the opt-in
    /// `--no-timeout` mode so long-running validation (e.g. `dart test`,
    /// `zig build test`) is captured instead of being killed (FR-003).
    pub const no_timeout: u64 = std.math.maxInt(u64);

    fn execute(ctx: *anyopaque, alloc: Allocator, args_json: []const u8) !ToolResult {
        const self: *BashTool = @ptrCast(@alignCast(ctx));
        const Args = struct { command: []const u8 };
        var parsed = try std.json.parseFromSlice(Args, alloc, args_json, .{});
        defer parsed.deinit();

        // FR-002: refuse an unauthorized remote `git push` instead of executing.
        if (!self.allow_push and isUnauthorizedGitPush(parsed.value.command)) {
            self.push_blocked = true;
            return ToolResult{
                .ok = false,
                .error_message = try std.fmt.allocPrint(alloc,
                    "run_command blocked: `git push` to a remote requires authorization (re-run with --allow-push)", .{}),
            };
        }

        var argv = [_][]const u8{ "/bin/sh", "-c", parsed.value.command };
        var child = std.process.Child.init(&argv, alloc);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        try child.spawn();

        const r = try runWithTimeout(alloc, &child, self.timeout_seconds);
        // FR-002: record a successful authorized push for the job report.
        if (self.allow_push and isUnauthorizedGitPush(parsed.value.command) and r.ok) {
            self.push_occurred = true;
        }
        return r;
    }
};

/// True when `cmd` is a `git push` that would reach a remote and is not a
/// dry-run. Used to gate pushes behind explicit authorization (FR-002). The
/// command must begin with `git` so incidental mentions (e.g. `echo "git push"`)
/// are not mistaken for a real push.
fn isUnauthorizedGitPush(cmd: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, cmd, ' ');
    const first = it.next() orelse return false;
    if (!std.mem.eql(u8, first, "git")) return false;
    var saw_push = false;
    var dry_run = false;
    while (it.next()) |tok| {
        if (std.mem.eql(u8, tok, "push")) saw_push = true;
        if (std.mem.eql(u8, tok, "--dry-run")) dry_run = true;
    }
    return saw_push and !dry_run;
}

/// Spawn the child, drain both stdout and stderr to EOF via `poll`, then reap
/// with a single `child.wait()`. On timeout the child is signalled (SIGTERM)
/// and a failure result is returned instead of blocking forever.
fn runWithTimeout(alloc: Allocator, child: *std.process.Child, timeout_seconds: u64) !ToolResult {
    var out_buf = try std.ArrayList(u8).initCapacity(alloc, 0);
    defer out_buf.deinit(alloc);
    var err_buf = try std.ArrayList(u8).initCapacity(alloc, 0);
    defer err_buf.deinit(alloc);
    // ChildProcess has no deinit() in this Zig version; close the pipe fds
    // (and their wrapping std.fs.File buffers) explicitly to avoid leaking them.
    defer {
        if (child.stdout) |s| s.close();
        if (child.stderr) |e| e.close();
    }

    const out_fd = child.stdout.?.handle;
    const err_fd = child.stderr.?.handle;
    var out_done = false;
    var err_done = false;
    var tmp: [4096]u8 = undefined;

    const start_ms = std.time.milliTimestamp();
    while (!out_done or !err_done) {
        // Bounded timeout: abort a hung command (FR-008 edge case). When the
        // budget is `no_timeout` we never kill — long validation must complete
        // and its result be captured (FR-003).
        if (timeout_seconds != BashTool.no_timeout) {
            const elapsed_ms: u64 = @intCast(std.time.milliTimestamp() - start_ms);
            if (elapsed_ms >= timeout_seconds * 1000) {
                std.posix.kill(child.id, std.posix.SIG.TERM) catch {};
                return ToolResult{
                    .ok = false,
                    .error_message = try std.fmt.allocPrint(alloc, "run_command timed out after {d}s", .{timeout_seconds}),
                };
            }
        }

        var fds: [2]std.posix.pollfd = undefined;
        var nfd: usize = 0;
        if (!out_done) {
            fds[nfd] = .{ .fd = out_fd, .events = std.posix.POLL.IN, .revents = 0 };
            nfd += 1;
        }
        if (!err_done) {
            fds[nfd] = .{ .fd = err_fd, .events = std.posix.POLL.IN, .revents = 0 };
            nfd += 1;
        }
        _ = std.posix.poll(fds[0..nfd], 200) catch 0;

        for (fds[0..nfd]) |*p| {
            if (p.revents == 0) continue;
            const readable = (p.revents & std.posix.POLL.IN) != 0;
            const hung = (p.revents & (std.posix.POLL.HUP | std.posix.POLL.ERR | std.posix.POLL.NVAL)) != 0;
            if (!readable) {
                // No data left to read (hangup/error); mark this stream done.
                if (p.fd == out_fd) out_done = true else err_done = true;
                continue;
            }
            const n = if (p.fd == out_fd)
                std.posix.read(out_fd, &tmp) catch 0
            else
                std.posix.read(err_fd, &tmp) catch 0;
            if (n == 0) {
                if (p.fd == out_fd) out_done = true else err_done = true;
                continue;
            }
            const buf = if (p.fd == out_fd) &out_buf else &err_buf;
            if (buf.items.len < BashTool.max_output_bytes) {
                try buf.appendSlice(alloc, tmp[0..n]);
            }
            _ = hung;
        }
    }

    const term = child.wait() catch std.process.Child.Term{ .Exited = 1 };
    const code: i64 = switch (term) {
        .Exited => |c| c,
        else => -1,
    };
    const combined = try std.fmt.allocPrint(alloc, "exit={d}\n{s}{s}", .{ code, out_buf.items, err_buf.items });
    const ok = switch (term) {
        .Exited => |c| c == 0,
        else => false,
    };
    return ToolResult{ .ok = ok, .output = combined };
}

test "BashTool runs a command" {
    var fake = @import("../fs/fs.zig").FakeFs.init(std.testing.allocator, "/wd");
    var bt = BashTool.init(fake.toFs(), false, 600);
    const t = bt.toTool();
    const r = try t.execute(std.testing.allocator, "{\"command\":\"echo hello\"}");
    defer std.testing.allocator.free(r.output);
    try std.testing.expect(r.ok);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "hello") != null);
}

test "isUnauthorizedGitPush classifies push commands" {
    try std.testing.expect(isUnauthorizedGitPush("git push origin main"));
    try std.testing.expect(isUnauthorizedGitPush("git push"));
    try std.testing.expect(isUnauthorizedGitPush("git   push   origin   main"));
    try std.testing.expect(!isUnauthorizedGitPush("git push --dry-run origin main"));
    try std.testing.expect(!isUnauthorizedGitPush("git push --dry-run"));
    try std.testing.expect(!isUnauthorizedGitPush("echo git push"));
    try std.testing.expect(!isUnauthorizedGitPush("git status"));
    try std.testing.expect(!isUnauthorizedGitPush("push origin main"));
}

test "BashTool refuses an unauthorized git push" {
    var fake = @import("../fs/fs.zig").FakeFs.init(std.testing.allocator, "/wd");
    var bt = BashTool.init(fake.toFs(), false, 600);
    const t = bt.toTool();
    const r = try t.execute(std.testing.allocator, "{\"command\":\"git push origin main\"}");
    defer if (r.error_message) |e| std.testing.allocator.free(e);
    try std.testing.expect(!r.ok);
    try std.testing.expect(bt.push_blocked);
    try std.testing.expect(std.mem.indexOf(u8, r.error_message.?, "blocked") != null);
}

test "BashTool honors a custom timeout and no-timeout (FR-003)" {
    const alloc = std.testing.allocator;

    // A 1s sleep killed by a 0s timeout.
    var fake0 = @import("../fs/fs.zig").FakeFs.init(alloc, "/wd");
    var bt0 = BashTool.init(fake0.toFs(), false, 0);
    const t0 = bt0.toTool();
    const r0 = try t0.execute(alloc, "{\"command\":\"sleep 1\"}");
    defer if (r0.error_message) |e| alloc.free(e);
    try std.testing.expect(!r0.ok);
    try std.testing.expect(std.mem.indexOf(u8, r0.error_message.?, "timed out") != null);

    // The same 1s sleep completes under a long / no-timeout budget.
    var fake1 = @import("../fs/fs.zig").FakeFs.init(alloc, "/wd");
    var bt1 = BashTool.init(fake1.toFs(), false, BashTool.no_timeout);
    const t1 = bt1.toTool();
    const r1 = try t1.execute(alloc, "{\"command\":\"sleep 1 && echo done\"}");
    defer {
        alloc.free(r1.output);
        if (r1.error_message) |e| alloc.free(e);
    }
    try std.testing.expect(r1.ok);
    try std.testing.expect(std.mem.indexOf(u8, r1.output, "done") != null);
}

test "BashTool times out a hanging command" {
    const alloc = std.testing.allocator;
    var argv = [_][]const u8{ "/bin/sh", "-c", "sleep 5" };
    var child = std.process.Child.init(&argv, alloc);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const r = try runWithTimeout(alloc, &child, 0);
    try std.testing.expect(!r.ok);
    try std.testing.expect(std.mem.indexOf(u8, r.error_message.?, "timed out") != null);
    alloc.free(r.error_message.?);
}

test "BashTool captures large stderr without truncation" {
    // Regression: output must be fully drained (poll loop, not a racing pair
    // of reader threads) or a command with substantial stderr loses data.
    const alloc = std.testing.allocator;
    var argv = [_][]const u8{ "/bin/sh", "-c", "for i in $(seq 1 3000); do echo \"L$i\" 1>&2; done" };
    var child = std.process.Child.init(&argv, alloc);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const r = try runWithTimeout(alloc, &child, 30);
    defer {
        alloc.free(r.output);
        if (r.error_message) |e| alloc.free(e);
    }
    try std.testing.expect(r.ok);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "L3000") != null);
}

test "BashTool captures merged 2>&1 piped output" {
    // Regression: a command that writes to stderr and is merged to stdout via
    // `2>&1`, then piped through `tail`, must be captured fully (not empty).
    // NOTE: must NOT call `zig build test` here — that would recursively run
    // this test suite again and hang the build.
    const alloc = std.testing.allocator;
    var argv = [_][]const u8{ "/bin/sh", "-c", "for i in $(seq 1 100); do echo S$i 1>&2; done 2>&1 | tail -3" };
    var child = std.process.Child.init(&argv, alloc);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const r = try runWithTimeout(alloc, &child, 30);
    defer {
        alloc.free(r.output);
        if (r.error_message) |e| alloc.free(e);
    }
    try std.testing.expect(r.ok);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "S100") != null);
}
