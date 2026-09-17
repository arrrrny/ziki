const std = @import("std");
const Allocator = std.mem.Allocator;
const compat = @import("../compat.zig");
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
        if (!self.allow_push) {
            const g = classifyGitPush(parsed.value.command);
            if (g.gated()) {
                self.push_blocked = true;
                const msg = switch (g.verdict) {
                    // Review (safe-list gaps): an unknown subcommand deserves
                    // its own message — "git push" misdescribes the command.
                    .push => try std.fmt.allocPrint(alloc, "run_command blocked: `git push` to a remote requires authorization (re-run with --allow-push)", .{}),
                    .unknown_sub => try std.fmt.allocPrint(alloc, "run_command blocked: unknown git subcommand `{s}` — possible push alias; requires authorization (re-run with --allow-push)", .{g.sub orelse "?"}),
                    .safe => unreachable,
                };
                return ToolResult{ .ok = false, .error_message = msg };
            }
        }

        var argv = [_][]const u8{ "/bin/sh", "-c", parsed.value.command };
        var child = try std.process.spawn(compat.io(), .{
            .argv = &argv,
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .pipe,
        });

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

/// True when `cmd` would run a `git push` that reaches a remote and is not a
/// dry-run. Used to gate pushes behind explicit authorization (FR-002).
/// Intent is resolved shell-style, so incidental mentions (e.g. `echo "git
/// push"`) are not mistaken for a real push.
fn isUnauthorizedGitPush(cmd: []const u8) bool {
    return segmentCouldPush(cmd, 0).gated();
}

/// Full verdict with the offending subcommand, for the block message
/// (a definite push vs an unknown git subcommand that could be a push alias).
fn classifyGitPush(cmd: []const u8) Gate {
    return segmentCouldPush(cmd, 0);
}

/// Outcome of intent analysis for a command line: `safe` (allow),
/// `unknown_sub` (unrecognized git subcommand — fail closed) or `push`
/// (definite push). `sub` names the offending subcommand when known.
const Gate = struct {
    verdict: enum { safe, unknown_sub, push } = .safe,
    sub: ?[]const u8 = null,

    /// Keep the stronger of the two verdicts (safe < unknown_sub < push).
    fn merge(self: *Gate, other: Gate) void {
        if (@intFromEnum(other.verdict) > @intFromEnum(self.verdict)) self.* = other;
    }
    fn gated(self: Gate) bool {
        return self.verdict != .safe;
    }
    /// Nesting too deep or an unextractable surface — treat as a push.
    fn failClosed() Gate {
        return .{ .verdict = .push };
    }
};

/// Spec 016 (issue #19): resolve intent, not raw text. The command line is
/// split on top-level separators (quote-aware: `&&`, `||`, `;`, `|`, `&`,
/// and newline — everything `/bin/sh -c` treats as a command boundary); each
/// segment is either a shell wrapper (`sh|bash|zsh|dash -c <script>` —
/// recursed, depth capped) or analyzed as a `git` invocation. Command
/// substitution bodies (`$( … )`, backticks — including inside double quotes,
/// where the shell still substitutes) are recursed the same way; a body that
/// cannot be extracted fails closed. Unknown git subcommands fail closed
/// (a configured alias could expand to a push).
fn segmentCouldPush(seg: []const u8, depth: usize) Gate {
    if (depth > 3) return Gate.failClosed(); // nesting too deep — fail closed
    var g = Gate{};
    var i: usize = 0;
    var start: usize = 0;
    var quote: u8 = 0;
    while (i < seg.len) : (i += 1) {
        const c = seg[i];
        if (quote != 0) {
            if (c == quote) {
                quote = 0;
            } else if (quote == '"') {
                // Inside double quotes command substitution still executes.
                if (c == '`') {
                    const close = std.mem.indexOfScalarPos(u8, seg, i + 1, '`') orelse return Gate.failClosed();
                    g.merge(segmentCouldPush(seg[i + 1 .. close], depth + 1));
                    if (g.gated()) return g;
                    i = close;
                } else if (c == '$' and i + 1 < seg.len and seg[i + 1] == '(') {
                    const end = substitutionEnd(seg, i, depth) orelse return Gate.failClosed();
                    i = end - 1;
                }
            }
            continue;
        }
        if (c == '\'' or c == '"') {
            quote = c;
            continue;
        }
        // A backticked body runs wherever it appears (outside single quotes).
        if (c == '`') {
            const close = std.mem.indexOfScalarPos(u8, seg, i + 1, '`') orelse return Gate.failClosed();
            g.merge(segmentCouldPush(seg[i + 1 .. close], depth + 1));
            if (g.gated()) return g;
            i = close;
            continue;
        }
        // `$( … )` runs wherever it appears (POSIX command substitution).
        if (c == '$' and i + 1 < seg.len and seg[i + 1] == '(') {
            const end = substitutionEnd(seg, i, depth) orelse return Gate.failClosed();
            i = end - 1;
            continue;
        }
        const compound = (c == '&' and i + 1 < seg.len and seg[i + 1] == '&') or
            (c == '|' and i + 1 < seg.len and seg[i + 1] == '|') or
            c == ';' or c == '|' or c == '\n' or c == '&';
        if (compound) {
            g.merge(analyzeSegment(seg[start..i], depth));
            if (g.gated()) return g;
            // Skip only the second char of a doubled operator; a lone `&`
            // starts the next segment right after it.
            if (c != '\n' and i + 1 < seg.len and seg[i + 1] == c) i += 1;
            start = i + 1;
        }
    }
    g.merge(analyzeSegment(seg[start..], depth));
    return g;
}

/// The `$( … )` body at `i` (`seg[i] == '$'`, `seg[i + 1] == '('`) executes:
/// recurse into it (same fail-closed cap as the wrapper recursion) and return
/// the index just past the closing `)`. Null means the caller must gate —
/// the body could not be extracted (unterminated) or could push.
fn substitutionEnd(seg: []const u8, i: usize, depth: usize) ?usize {
    var d: usize = 1;
    var j = i + 2;
    while (j < seg.len) : (j += 1) {
        if (seg[j] == '(') {
            d += 1;
        } else if (seg[j] == ')') {
            d -= 1;
            if (d == 0) {
                if (segmentCouldPush(seg[i + 2 .. j], depth + 1).gated()) return null;
                return j + 1;
            }
        }
    }
    return null; // unterminated — fail closed
}

fn analyzeSegment(seg: []const u8, depth: usize) Gate {
    const trimmed = std.mem.trim(u8, seg, " \t\n\r");
    if (trimmed.len == 0) return Gate{};
    if (shellWrapperScript(trimmed)) |inner| return segmentCouldPush(inner, depth + 1);
    return gitSegmentPushes(trimmed);
}

/// `sh|bash|zsh|dash -c <script>`: returns the de-quoted script, else null.
fn shellWrapperScript(seg: []const u8) ?[]const u8 {
    var toks = SegTok{ .s = seg };
    const first = toks.next() orelse return null;
    const is_shell = wordIs(first, "sh") or wordIs(first, "bash") or
        wordIs(first, "zsh") or wordIs(first, "dash");
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

fn gitSegmentPushes(seg: []const u8) Gate {
    var toks = SegTok{ .s = seg };
    var first = toks.next() orelse return Gate{};
    // Shell word semantics: assignment prefixes (`FOO=bar cmd`) and
    // pass-through commands (`env`, `command`, `nohup`) still exec the
    // following program.
    while (true) {
        if (isAssignmentPrefix(first)) {
            first = toks.next() orelse return Gate{}; // assignment with no command — safe
            continue;
        }
        if (wordIs(first, "env") or wordIs(first, "command") or wordIs(first, "nohup")) {
            first = toks.next() orelse return Gate{};
            if (first.len > 0 and first[0] == '-') return Gate.failClosed(); // `env -i …` — unresolved form
            continue;
        }
        break;
    }
    if (!wordIs(first, "git")) return Gate{};
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
    const s = sub orelse return Gate{}; // bare `git` — safe
    if (wordIs(s, "push")) {
        if (dry_run) return Gate{};
        return .{ .verdict = .push };
    }
    if (!isKnownSafeGitSub(s)) return .{ .verdict = .unknown_sub, .sub = s };
    return Gate{};
}

/// Shell word semantics (review: program-name match): quotes never change a
/// word's letters and a path's basename is the program — `'git'`, `g"it"`,
/// `/usr/bin/git` all exec git.
fn wordIs(tok: []const u8, name: []const u8) bool {
    const base = if (std.mem.lastIndexOfScalar(u8, tok, '/')) |sl| tok[sl + 1 ..] else tok;
    var n: usize = 0;
    for (base) |c| {
        if (c == '\'' or c == '"') continue;
        if (n >= name.len or name[n] != c) return false;
        n += 1;
    }
    return n == name.len;
}

/// `NAME=value` environment assignment before a command (the shell assigns,
/// then execs the rest).
fn isAssignmentPrefix(tok: []const u8) bool {
    if (tok.len == 0 or tok[0] == '-' or tok[0] == '=') return false;
    return std.mem.indexOfScalar(u8, tok, '=') != null;
}

/// Known subcommands that cannot reach a remote with new state. Anything not
/// listed is treated as a possible alias for a push (fail closed).
fn isKnownSafeGitSub(s: []const u8) bool {
    const safe = [_][]const u8{
        "status",      "log",           "diff",         "show",        "add",          "commit",
        "mv",          "rm",            "stash",        "branch",      "tag",          "checkout",
        "switch",      "restore",       "merge",        "rebase",      "fetch",        "config",
        "remote",      "blame",         "describe",     "rev-parse",   "clean",        "apply",
        "cherry-pick", "revert",        "reset",        "grep",        "ls-files",     "ls-remote",
        "worktree",    "gc",            "fsck",         "notes",       "archive",      "bundle",
        "cat-file",    "check-ignore",  "init",         "clone",       "help",         "version",
        "reflog",      "merge-base",    "shortlog",     "bisect",      "submodule",    "ls-tree",
        "rev-list",    "show-branch",   "symbolic-ref", "whatchanged", "format-patch", "difftool",
        "var",         "count-objects", "maintenance",
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
    // (and their wrapping file handles) explicitly to avoid leaking them.
    defer {
        if (child.stdout) |s| s.close(compat.io());
        if (child.stderr) |e| e.close(compat.io());
    }

    const out_fd = child.stdout.?.handle;
    const err_fd = child.stderr.?.handle;
    var out_done = false;
    var err_done = false;
    var tmp: [4096]u8 = undefined;

    const start_ms = compat.milliTimestamp();
    while (!out_done or !err_done) {
        // Mid-command abort (spec 013 T10): observe the stop signal inside the
        // poll loop and terminate the child promptly.
        if (stop) |p| {
            if (p.isStop()) {
                was_aborted.* = true;
                std.posix.kill(child.id.?, std.posix.SIG.TERM) catch {};
                // Reap so the aborted command does not linger as a zombie with
                // open pipe fds for the life of the session; SIGTERM's default
                // action ends it promptly.
                _ = child.wait(compat.io()) catch std.process.Child.Term{ .exited = 1 };
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
            const elapsed_ms: u64 = @intCast(compat.milliTimestamp() - start_ms);
            if (elapsed_ms >= timeout_seconds * 1000) {
                std.posix.kill(child.id.?, std.posix.SIG.TERM) catch {};
                // Reap the timed-out child (no zombie / leaked fds).
                _ = child.wait(compat.io()) catch std.process.Child.Term{ .exited = 1 };
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

    const term = child.wait(compat.io()) catch std.process.Child.Term{ .exited = 1 };
    const code: i64 = switch (term) {
        .exited => |c| c,
        else => -1,
    };
    const combined = try std.fmt.allocPrint(alloc, "exit={d}\n{s}{s}", .{ code, out_buf.items, err_buf.items });
    const ok = switch (term) {
        .exited => |c| c == 0,
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
    var child = try std.process.spawn(compat.io(), .{
        .argv = &argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
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
    var child = try std.process.spawn(compat.io(), .{
        .argv = &argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
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
    var child = try std.process.spawn(compat.io(), .{
        .argv = &argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
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
        // Review follow-ups (spec 016): the same gate must hold for the other
        // top-level separators and for shell word semantics.
        "echo hi & git push origin main", // lone `&` backgrounds, then pushes
        "set -e\ngit push origin main", // newline is a command separator
        "'git' push origin main", // quoted program name
        "g\"it\" push origin main", // partially quoted program name
        "/usr/bin/git push origin main", // the basename is the program
        "env git push origin main", // pass-through prefix
        "command git push origin main",
        "nohup git push origin main",
        "FOO=bar git push origin main", // assignment prefix
        "env VAR=1 git push origin main",
        "\"bash\" -c 'git push origin main'", // quoted wrapper program name
        "echo $(git push origin main)", // command substitution body
        "echo `git push origin main`", // backtick body
        "git commit -m \"hi $(git push origin main)\"", // substitution inside double quotes
        "bash <<'EOF'\ngit push origin main\nEOF", // heredoc body runs
        "echo $(git push", // unterminated substitution — fail closed
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
        // Safe substitution and suppressed substitution stay allowed.
        "git commit -m \"fix $(date)\"",
        "git commit -m 'literal $(git push)'",
        // Newly safe-listed local subcommands must not be gated.
        "git reflog",
        "git merge-base HEAD~1 HEAD",
        "git submodule status",
        "git rev-list --count HEAD",
        "git count-objects",
    };
    for (allowed) |cmd| {
        if (isUnauthorizedGitPush(cmd)) {
            std.debug.print("SAFE command gated: {s}\n", .{cmd});
            return error.SafeCommandGated;
        }
    }
}

test "unknown git subcommand blocks with a push-alias message" {
    const alloc = std.testing.allocator;
    var fake = @import("../fs/fs.zig").FakeFs.init(alloc, "/wd");
    var bt = BashTool.init(fake.toFs(), false, 600);
    const t = bt.toTool();
    const r = try t.execute(alloc, "{\"command\":\"git deploy-all\"}");
    defer if (r.error_message) |e| alloc.free(e);
    try std.testing.expect(!r.ok);
    try std.testing.expect(bt.push_blocked);
    try std.testing.expect(std.mem.indexOf(u8, r.error_message.?, "unknown git subcommand") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.error_message.?, "deploy-all") != null);
}
