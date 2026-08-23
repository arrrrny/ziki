const std = @import("std");
const Allocator = std.mem.Allocator;

const config = @import("config/config.zig");
const presets = @import("provider/presets.zig");
const HttpTransport = @import("provider/transport.zig").HttpTransport;
const RealFs = @import("fs/fs.zig").RealFs;
const Fs = @import("fs/fs.zig").Fs;
const GoalExecutor = @import("agent/executor.zig").GoalExecutor;
const Goal = @import("goal/goal.zig").Goal;
const Status = @import("goal/goal.zig").Status;
const FsGoalRepository = @import("goal/repository.zig").FsGoalRepository;
const Tool = @import("tool/tool.zig").Tool;
const ReadTool = @import("tool/read.zig").ReadTool;
const EditTool = @import("tool/edit.zig").EditTool;
const SearchTool = @import("tool/search.zig").SearchTool;
const WriteTool = @import("tool/write.zig").WriteTool;
const BashTool = @import("tool/bash.zig").BashTool;

const Intent = @import("shell/intent.zig").Intent;
const Result = @import("shell/intent.zig").Result;
const Handler = @import("shell/handler.zig").Handler;
const Dispatcher = @import("shell/dispatcher.zig").Dispatcher;
const parser = @import("shell/parser.zig");
const Repl = @import("shell/repl.zig");
const Output = @import("shell/repl.zig").Output;

const SESSION_ID = "default";

fn emit(comptime fmt: []const u8, args: anytype) !void {
    const s = try std.fmt.allocPrint(std.heap.page_allocator, fmt ++ "\n", args);
    defer std.heap.page_allocator.free(s);
    try std.fs.File.stdout().writeAll(s);
}
fn emitErr(msg: []const u8) !void {
    try std.fs.File.stdout().writeAll("error: ");
    try std.fs.File.stdout().writeAll(msg);
    try std.fs.File.stdout().writeAll("\n");
}
fn emitStatus(status: Status) !void {
    try emit("status: {s}", .{status.jsonString()});
}
fn emitSummary(goal: *const Goal) !void {
    try emit("summary:", .{});
    try emit("  objective: {s}", .{goal.objective});
    try emit("  status:    {s}", .{goal.status.jsonString()});
    try emit("  progress:  {s}", .{goal.progress});
}

fn sessionProviderPath(alloc: Allocator, state_dir: []const u8) ![]u8 {
    return std.fs.path.join(alloc, &.{ state_dir, "provider.txt" });
}
fn readSessionProvider(alloc: Allocator, state_dir: []const u8) !?[]const u8 {
    const p = try sessionProviderPath(alloc, state_dir);
    defer alloc.free(p);
    const raw = std.fs.cwd().readFileAlloc(alloc, p, 256) catch return null;
    const trimmed = std.mem.trim(u8, raw, "\r\n");
    if (trimmed.len == 0) {
        alloc.free(raw);
        return null;
    }
    const owned = try alloc.dupe(u8, trimmed);
    alloc.free(raw);
    return owned;
}
fn writeSessionProvider(alloc: Allocator, state_dir: []const u8, name: []const u8) !void {
    const p = try sessionProviderPath(alloc, state_dir);
    defer alloc.free(p);
    try std.fs.cwd().writeFile(.{ .sub_path = p, .data = name });
}

// ---------------------------------------------------------------------------
// Command handlers. Each wraps the existing logic behind the Handler interface
// so the dispatcher stays command-agnostic (SC-005, DIP).
// ---------------------------------------------------------------------------

fn runGoal(alloc: Allocator, tokens: [][]const u8, state_dir: []const u8, fs_iface: Fs) !void {
    if (tokens.len < 2) {
        try emitErr("goal objective must not be empty");
        return;
    }
    var objective_parts = try std.ArrayList([]const u8).initCapacity(alloc, 0);
    defer objective_parts.deinit(alloc);
    var criterion: ?[]const u8 = null;
    var provider_override: ?[]const u8 = null;
    var verbose = false;

    var i: usize = 1;
    while (i < tokens.len) : (i += 1) {
        const t = tokens[i];
        if (std.mem.eql(u8, t, "--criterion")) {
            if (i + 1 >= tokens.len) {
                try emitErr("missing value for --criterion");
                return;
            }
            criterion = tokens[i + 1];
            i += 1;
        } else if (std.mem.startsWith(u8, t, "--criterion=")) {
            criterion = t["--criterion=".len..];
        } else if (std.mem.eql(u8, t, "--provider")) {
            if (i + 1 >= tokens.len) {
                try emitErr("missing value for --provider");
                return;
            }
            provider_override = tokens[i + 1];
            i += 1;
        } else if (std.mem.startsWith(u8, t, "--provider=")) {
            provider_override = t["--provider=".len..];
        } else if (std.mem.eql(u8, t, "--verbose") or std.mem.eql(u8, t, "-v")) {
            verbose = true;
        } else {
            try objective_parts.append(alloc, t);
        }
    }
    if (objective_parts.items.len == 0) {
        try emitErr("goal objective must not be empty");
        return;
    }
    const objective = try std.mem.join(alloc, " ", objective_parts.items);
    defer alloc.free(objective);

    const cfg = config.load(alloc) catch {
        try emitErr("no provider configured — set one via /provider or config");
        return;
    };
    defer cfg.deinit(alloc);
    const session_prov = readSessionProvider(alloc, state_dir) catch null;
    defer if (session_prov) |sp| alloc.free(sp);
    const effective = provider_override orelse (session_prov orelse cfg.active_provider);
    if (presets.findPreset(effective) == null) {
        try emitErr("unknown provider — must be one of the six required providers");
        return;
    }

    var transport = HttpTransport.init(alloc, if (cfg.proxy.len > 0) cfg.proxy else null) catch {
        try emitErr("invalid proxy URL in configuration");
        return;
    };
    defer transport.deinit();
    var prov_impl = presets.build(alloc, effective, cfg.endpoint, cfg.model, cfg.api_key, transport.toTransport()) catch {
        try emitErr("could not build provider");
        return;
    };
    const prov = prov_impl.toProvider();

    var rt = ReadTool.init(fs_iface);
    const read_t = rt.toTool();
    var et = EditTool.init(fs_iface);
    const edit_t = et.toTool();
    var sct = SearchTool.init(fs_iface);
    const search_t = sct.toTool();
    var wt = WriteTool.init(fs_iface);
    const write_t = wt.toTool();
    var bt = BashTool.init(fs_iface);
    const bash_t = bt.toTool();
    const tools = [_]Tool{ read_t, edit_t, search_t, write_t, bash_t };

    var repo_impl = FsGoalRepository.init(fs_iface, state_dir, SESSION_ID);
    const repo = repo_impl.toRepository();

    var ex = GoalExecutor{
        .alloc = alloc,
        .provider = prov,
        .tools = &tools,
        .repo = repo,
        .fs = fs_iface,
        .dir = state_dir,
        .session_id = SESSION_ID,
        .verbose = verbose,
    };

    var goal = try Goal.init(alloc, objective, criterion, SESSION_ID);
    defer goal.deinit(alloc);
    try emitStatus(.active);
    try ex.run(&goal);
    try emitStatus(goal.status);
    try emitSummary(&goal);
}

fn runStop(alloc: Allocator, state_dir: []const u8) !void {
    const p = try std.fs.path.join(alloc, &.{ state_dir, "stop." ++ SESSION_ID });
    defer alloc.free(p);
    std.fs.cwd().writeFile(.{ .sub_path = p, .data = "" }) catch {
        try emitErr("could not write stop signal");
        return;
    };
    try emit("stop signal set; the active goal will abort on its next turn", .{});
}

fn runStatus(alloc: Allocator, state_dir: []const u8, fs_iface: Fs) !void {
    var repo_impl = FsGoalRepository.init(fs_iface, state_dir, SESSION_ID);
    const repo = repo_impl.toRepository();
    const g = repo.load(alloc) catch null;
    if (g == null) {
        try emit("no active goal", .{});
        return;
    }
    var goal = g.?;
    defer goal.deinit(alloc);
    try emit("objective: {s}", .{goal.objective});
    try emitStatus(goal.status);
    try emit("progress:  {s}", .{goal.progress});
    try emit("turns:     {d}/{d}", .{ goal.used.turns, goal.budgets.max_turns });
}

fn runGoals(alloc: Allocator, state_dir: []const u8, fs_iface: Fs) !void {
    var repo_impl = FsGoalRepository.init(fs_iface, state_dir, SESSION_ID);
    const repo = repo_impl.toRepository();
    const g = repo.load(alloc) catch null;
    if (g == null) {
        try emit("no active goal", .{});
        return;
    }
    var goal = g.?;
    defer goal.deinit(alloc);
    try emit("goal: {s}", .{goal.objective});
    try emitStatus(goal.status);
}

fn runProvider(alloc: Allocator, tokens: [][]const u8, state_dir: []const u8) !void {
    if (tokens.len < 2) {
        const p = try readSessionProvider(alloc, state_dir);
        const name = p orelse "none (using config)";
        try emit("active provider: {s}", .{name});
        return;
    }
    const name = tokens[1];
    if (presets.findPreset(name) == null) {
        try emitErr("unknown provider — must be one of: opencode, kilo, zai, kimi, openai_custom, cliproxy");
        return;
    }
    try writeSessionProvider(alloc, state_dir, name);
    try emit("active provider set to {s}", .{name});
}

// --- Handler context structs + vtable bindings ---

const GoalCtx = struct { state_dir: []const u8, fs: Fs };
const StopCtx = struct { state_dir: []const u8 };
const ProviderCtx = struct { state_dir: []const u8 };
const StatusCtx = struct { state_dir: []const u8, fs: Fs };
const GoalsCtx = struct { state_dir: []const u8, fs: Fs };
const HelpCtx = struct {};

fn goalHandle(ctx_: *anyopaque, alloc: Allocator, intent: Intent) !Result {
    const self: *GoalCtx = @ptrCast(@alignCast(ctx_));
    var toks = try std.ArrayList([]const u8).initCapacity(alloc, 0);
    defer toks.deinit(alloc);
    try toks.append(alloc, "/goal");
    var it = std.mem.tokenizeScalar(u8, intent.args, ' ');
    while (it.next()) |t| try toks.append(alloc, t);
    runGoal(alloc, toks.items, self.state_dir, self.fs) catch {};
    return Result{ .output = try alloc.dupe(u8, "") };
}
fn stopHandle(ctx_: *anyopaque, alloc: Allocator, intent: Intent) !Result {
    const self: *StopCtx = @ptrCast(@alignCast(ctx_));
    _ = intent;
    runStop(alloc, self.state_dir) catch {};
    return Result{ .output = try alloc.dupe(u8, "") };
}
fn providerHandle(ctx_: *anyopaque, alloc: Allocator, intent: Intent) !Result {
    const self: *ProviderCtx = @ptrCast(@alignCast(ctx_));
    var toks = try std.ArrayList([]const u8).initCapacity(alloc, 0);
    defer toks.deinit(alloc);
    try toks.append(alloc, "/provider");
    var it = std.mem.tokenizeScalar(u8, intent.args, ' ');
    while (it.next()) |t| try toks.append(alloc, t);
    runProvider(alloc, toks.items, self.state_dir) catch {};
    return Result{ .output = try alloc.dupe(u8, "") };
}
fn statusHandle(ctx_: *anyopaque, alloc: Allocator, intent: Intent) !Result {
    const self: *StatusCtx = @ptrCast(@alignCast(ctx_));
    _ = intent;
    runStatus(alloc, self.state_dir, self.fs) catch {};
    return Result{ .output = try alloc.dupe(u8, "") };
}
fn goalsHandle(ctx_: *anyopaque, alloc: Allocator, intent: Intent) !Result {
    const self: *GoalsCtx = @ptrCast(@alignCast(ctx_));
    _ = intent;
    runGoals(alloc, self.state_dir, self.fs) catch {};
    return Result{ .output = try alloc.dupe(u8, "") };
}
fn helpHandle(_: *anyopaque, _: Allocator, _: Intent) !Result {
    try emit("commands:", .{});
    try emit("  /goal <objective> [--criterion \"...\"] [--provider <name>] [--verbose]", .{});
    try emit("  /stop", .{});
    try emit("  /status", .{});
    try emit("  /goals", .{});
    try emit("  /provider [name]", .{});
    try emit("  /help", .{});
    return Result{ .output = try std.heap.page_allocator.dupe(u8, "") };
}

const goal_vtable = Handler.VTable{ .handle = goalHandle };
const stop_vtable = Handler.VTable{ .handle = stopHandle };
const provider_vtable = Handler.VTable{ .handle = providerHandle };
const status_vtable = Handler.VTable{ .handle = statusHandle };
const goals_vtable = Handler.VTable{ .handle = goalsHandle };
const help_vtable = Handler.VTable{ .handle = helpHandle };

// --- REPL output sink: stdout ---

var stdout_ctx: u8 = 0;
fn stdoutWrite(_: *anyopaque, data: []const u8) void {
    std.fs.File.stdout().writeAll(data) catch {};
}
const stdout_output = Output{ .ctx = &stdout_ctx, .vtable = &.{ .write = stdoutWrite } };

fn stdinRead(ctx: *std.fs.File, buf: []u8) error{}!usize {
    return ctx.read(buf) catch 0;
}

fn runRepl(alloc: Allocator, dispatcher: *Dispatcher) !void {
    var stdin_file = std.fs.File.stdin();
    const stdin = std.io.GenericReader(*std.fs.File, error{}, stdinRead){ .context = &stdin_file };
    try Repl.run(alloc, stdin, stdout_output, dispatcher, "ziki> ");
}

fn usage() !void {
    try emit("usage:", .{});
    try emit("  ziki /goal \"<objective>\" [--criterion \"<text>\"] [--provider <name>] [--verbose]", .{});
    try emit("  ziki /status", .{});
    try emit("  ziki /stop", .{});
    try emit("  ziki /goals", .{});
    try emit("  ziki /provider [name]", .{});
    try emit("  ziki            (interactive REPL)", .{});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();
    defer _ = gpa.deinit();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    const cwd = try std.process.getCwdAlloc(alloc);
    defer alloc.free(cwd);
    const state_dir = try std.fs.path.join(alloc, &.{ cwd, ".ziki" });
    defer alloc.free(state_dir);
    std.fs.cwd().makePath(state_dir) catch {};

    var realfs_impl = RealFs.init(cwd);
    const fs_iface = realfs_impl.toFs();

    // Composition root: build the dispatcher and inject the handlers.
    var gh = GoalCtx{ .state_dir = state_dir, .fs = fs_iface };
    var sh = StopCtx{ .state_dir = state_dir };
    var ph = ProviderCtx{ .state_dir = state_dir };
    var st = StatusCtx{ .state_dir = state_dir, .fs = fs_iface };
    var gl = GoalsCtx{ .state_dir = state_dir, .fs = fs_iface };
    var hp = HelpCtx{};

    var dispatcher = Dispatcher.init(alloc);
    defer dispatcher.deinit();
    try dispatcher.register("goal", .{ .ctx = &gh, .vtable = &goal_vtable });
    try dispatcher.register("stop", .{ .ctx = &sh, .vtable = &stop_vtable });
    try dispatcher.register("provider", .{ .ctx = &ph, .vtable = &provider_vtable });
    try dispatcher.register("status", .{ .ctx = &st, .vtable = &status_vtable });
    try dispatcher.register("goals", .{ .ctx = &gl, .vtable = &goals_vtable });
    try dispatcher.register("help", .{ .ctx = &hp, .vtable = &help_vtable });

    if (args.len < 2) {
        try runRepl(alloc, &dispatcher);
        return;
    }
    if (!std.mem.startsWith(u8, args[1], "/")) {
        try usage();
        return;
    }
    const line = try std.mem.join(alloc, " ", args[1..]);
    defer alloc.free(line);
    const intent = (try parser.parseLine(line)) orelse {
        try emitErr("empty command");
        return;
    };
    const result = dispatcher.dispatch(alloc, intent) catch |e| Result{
        .output = try std.fmt.allocPrint(alloc, "error: {s}", .{@errorName(e)}),
    };
    if (result.output.len > 0) try emit("{s}", .{result.output});
    alloc.free(result.output);
}
