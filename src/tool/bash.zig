const std = @import("std");
const Allocator = std.mem.Allocator;
const Tool = @import("tool.zig").Tool;
const ToolResult = @import("tool.zig").ToolResult;
const ToolSpec = @import("../provider/provider.zig").ToolSpec;
const Fs = @import("../fs/fs.zig").Fs;
const StopProbe = @import("../agent/stop.zig").StopProbe;

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
    /// Mid-command stop observation (spec 013 D5/T10). Checked every poll
    /// iteration (~200 ms); when it fires the child is SIGTERMed and the tool
    /// returns an aborted result so the goal loop unwinds immediately.
    stop: ?StopProbe = null,
    /// Set when this run was aborted via the stop probe (read by the executor/report).
    aborted: bool = false,

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

        var was_aborted = false;
        const r = try runWithTimeout(alloc, &child, self.timeout_seconds, self.stop, &was_aborted);
        if (was_aborted) self.aborted = true;
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
    return segmentCouldPush(cmd, 0);
}

/// Spec 016 (issue #19): resolve intent, not raw text. The command line is
/// split on top-level compound separators (quote-aware); each segment is
/// either a shell wrapper (`sh|bash|zsh|dash -c <script>` — recursed, depth
/// capped) or analyzed as a `git` invocation. Unknown git subcommands fail
/// closed (a configured alias could expand to a push).
fn segmentCouldPush(seg: []const u8, depth: usize) bool {
    if (depth > 3) return true; // nesting too deep — fail closed
    var i: usize = 0;
    var start: usize = 0;
    var quote: u8 = 0;
    while (i < seg.len) : (i += 1) {
        const c = seg[i];
        if (quote != 0) {
            if (c == quote) quote = 0;
            continue;
        }
        if (c == '\'' or c == '"') {
            quote = c;
            continue;
        }
        const compound = (c == '&' and i + 1 < seg.len and seg[i + 1] == '&') or
            (c == '|' and i + 1 < seg.len and seg[i + 1] == '|') or
            c == ';' or c == '|';
        if (compound) {
            if (analyzeSegment(seg[start..i], depth)) return true;
            if (c == '&' or c == '|') i += 1;
            start = i + 1;
        }
    }
    return analyzeSegment(seg[start..], depth);
}

fn analyzeSegment(seg: []const u8, depth: usize) bool {
    const trimmed = std.mem.trim(u8, seg, " \t\n\r");
    if (trimmed.len == 0) return false;
    if (shellWrapperScript(trimmed)) |inner| return segmentCouldPush(inner, depth + 1);
    return gitSegmentPushes(trimmed);
}

/// `sh|bash|zsh|dash -c <script>`: returns the de-quoted script, else null.
fn shellWrapperScript(seg: []const u8) ?[]const u8 {
    var toks = SegTok{ .s = seg };
    const first = toks.next() orelse return null;
    const is_shell = std.mem.eql(u8, first, "sh") or std.mem.eql(u8, first, "bash") or
        std.mem.eql(u8, first, "zsh") or std.mem.eql(u8, first, "dash");
    if (!is_shell) return null;
    var saw_c = false;
    while (toks.next()) |t| {
        if (std.mem.eql(u8, t, "-c")) {
            saw_c = true;
            continue;
        }
        if (saw_c) {
            var inner = t;
            if (inner.len >= 2 and (inner[0] == '\'' or inner[0] == '"') and inner[inner.len - 1] == inner[0]) {
                inner = inner[1 .. inner.len - 1];
            }
            return inner;
        }
    }
    return null;
}

fn gitSegmentPushes(seg: []const u8) bool {
    var toks = SegTok{ .s = seg };
    const first = toks.next() orelse return false;
    if (!std.mem.eql(u8, first, "git")) return false;
    var sub: ?[]const u8 = null;
    var dry_run = false;
    while (toks.next()) |t| {
        if (sub == null) {
            if (t.len > 0 and t[0] == '-') {
                // Global options that consume a following value.
                if (std.mem.eql(u8, t, "-C") or std.mem.eql(u8, t, "-c")) _ = toks.next();
                continue;
            }
            sub = t;
            continue;
        }
        if (std.mem.eql(u8, t, "--dry-run")) dry_run = true;
    }
    const s = sub orelse return false; // bare `git` — safe
    if (std.mem.eql(u8, s, "push")) return !dry_run;
    return !isKnownSafeGitSub(s);
}

/// Known subcommands that cannot reach a remote with new state. Anything not
/// listed is treated as a possible alias for a push (fail closed).
fn isKnownSafeGitSub(s: []const u8) bool {
    const safe = [_][]const u8{
        "status",   "log",     "diff",     "show",         "add",       "commit",
        "mv",       "rm",      "stash",    "branch",       "tag",       "checkout",
        "switch",   "restore", "merge",    "rebase",       "fetch",     "config",
        "remote",   "blame",   "describe", "rev-parse",    "clean",     "apply",
        "cherry-pick", "revert", "reset",  "grep",         "ls-files",  "ls-remote",
        "worktree", "gc",      "fsck",     "notes",        "archive",   "bundle",
        "cat-file", "check-ignore",       "init",         "clone",     "help",
        "version",
    };
    for (safe) |k| {
        if (std.mem.eql(u8, s, k)) return true;
    }
    return false;
}

/// Quote-aware whitespace tokenizer (quotes stay part of the token).
const SegTok = struct {
    s: []const u8,
    i: usize = 0,

    fn next(self: *SegTok) ?[]const u8 {
        while (self.i < self.s.len and (self.s[self.i] == ' ' or self.s[self.i] == '\t')) self.i += 1;
        if (self.i >= self.s.len) return null;
        const start = self.i;
        while (self.i < self.s.len and self.s[self.i] != ' ' and self.s[self.i] != '\t') {
            if (self.s[self.i] == '\'' or self.s[self.i] == '"') {
                const q = self.s[self.i];
                self.i += 1;
                while (self.i < self.s.len and self.s[self.i] != q) self.i += 1;
                if (self.i < self.s.len) self.i += 1;
                continue;
            }
            self.i += 1;
        }
        return self.s[start..self.i];
    }
};

/// Spawn the child, drain both stdout and stderr to EOF via `poll`, then reap
/// with a single `child.wait()`. On timeout (and on the stop signal) the child
/// is signalled (SIGTERM), reaped, and a failure result is returned instead of
/// blocking forever. When `stop` is provided it is polled every iteration and,
/// on fire, the child is SIGTERMed and an aborted result is returned
/// (spec 013 T10).
fn runWithTimeout(alloc: Allocator, child: *std.process.Child, timeout_seconds: u64, stop: ?StopProbe, was_aborted: *bool) !ToolResult {
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
        // Mid-command abort (spec 013 T10): observe the stop signal inside the
        // poll loop and terminate the child promptly.
        if (stop) |p| {
            if (p.isStop()) {
                was_aborted.* = true;
                std.posix.kill(child.id, std.posix.SIG.TERM) catch {};
                // Reap so the aborted command does not linger as a zombie with
                // open pipe fds for the life of the session; SIGTERM's default
                // action ends it promptly.
                _ = child.wait() catch std.process.Child.Term{ .Exited = 1 };
                return ToolResult{
                    .ok = false,
                    .error_message = try std.fmt.allocPrint(alloc, "run_command aborted by user", .{}),
                };
            }
        }
        // Bounded timeout: abort a hung command (FR-008 edge case). When the
        // budget is `no_timeout` we never kill — long validation must complete
        // and its result be captured (FR-003).
        if (timeout_seconds != BashTool.no_timeout) {
            const elapsed_ms: u64 = @intCast(std.time.milliTimestamp() - start_ms);
            if (elapsed_ms >= timeout_seconds * 1000) {
                std.posix.kill(child.id, std.posix.SIG.TERM) catch {};
                // Reap the timed-out child (no zombie / leaked fds).
                _ = child.wait() catch std.process.Child.Term{ .Exited = 1 };
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
    var ab0 = false;
    const r = try runWithTimeout(alloc, &child, 0, null, &ab0);
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
    var ab30 = false;
    const r = try runWithTimeout(alloc, &child, 30, null, &ab30);
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
    var ab30 = false;
    const r = try runWithTimeout(alloc, &child, 30, null, &ab30);
    defer {
        alloc.free(r.output);
        if (r.error_message) |e| alloc.free(e);
    }
    try std.testing.expect(r.ok);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "S100") != null);
}

// ---------------------------------------------------------------------------
// Tests: bypass shapes (spec 016 US1, issue #19 Lane D).
// ---------------------------------------------------------------------------

test "push gate catches compound, wrapper and alias bypass shapes (A1)" {
    const gated = [_][]const u8{
        "cd repo && git push origin main", // compound: push in the second segment
        "deploy && git push", // compound after another command
        "sh -c 'git push origin main'", // shell wrapper
        "bash -c \"git push\"", // wrapper, double quotes
        "zsh -c 'cd x && git push'", // wrapper + compound inside the script
        "git -C /srv/app push origin", // global option before the subcommand
        "git deploy-all", // unknown subcommand: alias could expand to a push
        "git -c http.extraHeader=x push", // -c consumes a value, then push
        "git push origin main # safe comment", // push is still a push
    };
    for (gated) |cmd| {
        if (!isUnauthorizedGitPush(cmd)) {
            std.debug.print("BYPASS not caught: {s}\n", .{cmd});
            return error.BypassNotCaught;
        }
    }

    const allowed = [_][]const u8{
        "git status",
        "git log --oneline",
        "git add -A && git commit -m x",
        "git push --dry-run",
        "echo git push",
        "ls; git log",
        "git commit -m 'msg says git push'",
    };
    for (allowed) |cmd| {
        if (isUnauthorizedGitPush(cmd)) {
            std.debug.print("SAFE command gated: {s}\n", .{cmd});
            return error.SafeCommandGated;
        }
    }
}
