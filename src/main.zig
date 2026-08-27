const std = @import("std");
const Allocator = std.mem.Allocator;

const config = @import("config/config.zig");
const presets = @import("provider/presets.zig");
const HttpTransport = @import("provider/transport.zig").HttpTransport;
const RealFs = @import("fs/fs.zig").RealFs;
const Fs = @import("fs/fs.zig").Fs;
const GoalExecutor = @import("agent/executor.zig").GoalExecutor;
const state = @import("agent/state.zig");
const herdr = @import("agent/herdr.zig");
const Transport = @import("provider/transport.zig").Transport;
const FakeTransport = @import("provider/transport.zig").FakeTransport;
const Goal = @import("goal/goal.zig").Goal;
const Status = @import("goal/goal.zig").Status;
const FsGoalRepository = @import("goal/repository.zig").FsGoalRepository;
const Tool = @import("tool/tool.zig").Tool;
const ReadTool = @import("tool/read.zig").ReadTool;
const EditTool = @import("tool/edit.zig").EditTool;
const SearchTool = @import("tool/search.zig").SearchTool;
const WriteTool = @import("tool/write.zig").WriteTool;
const BashTool = @import("tool/bash.zig").BashTool;
const skill_registry = @import("skill/registry.zig");
const SkillTool = @import("skill/tool.zig").SkillTool;
const skill_cmds = @import("skill/handler.zig");

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

/// AnyWriter that emits to stdout (fd 1). Used by the Herdr state publisher to
/// write the `[ziki-state: ...]` screen marker and OSC title. `std.fs.File`
/// lacks the new `Writer.any()` helper, so we build the `AnyWriter` directly.
fn stdoutWriteFn(_: *const anyopaque, bytes: []const u8) anyerror!usize {
    return std.fs.File.stdout().write(bytes);
}
fn stdoutAnyWriter() std.io.AnyWriter {
    return .{ .context = undefined, .writeFn = stdoutWriteFn };
}

/// Build the Herdr `StatePublisher` for a goal (spec 011, FR-008).
///
/// When `pane_id` is set, resolves the Herdr API URL and builds a real
/// `HerdrHttpClient` reporter (stored in `herdr_client_slot`, which the caller
/// owns and keeps alive for the run) so Ziki pushes state to Herdr. When
/// `pane_id` is null, returns a publisher with `reporter = null`: it still
/// emits the screen marker + OSC title but never pushes (degraded mode).
fn buildStatePublisher(
    alloc: Allocator,
    transport: Transport,
    pane_id: ?[]const u8,
    goal_id: []const u8,
    state_dir: []const u8,
    herdr_client_slot: *?herdr.HerdrHttpClient,
    writer: std.io.AnyWriter,
) !state.StatePublisher {
    var reporter: ?state.HerdrReporter = null;
    if (pane_id) |_| {
        const api_url = try herdr.resolveApiUrl(alloc);
        herdr_client_slot.* = herdr.HerdrHttpClient.init(alloc, transport, api_url);
        reporter = (herdr_client_slot.*).?.toReporter();
        alloc.free(api_url);
    }
    return state.StatePublisher.init(alloc, reporter, writer, pane_id orelse "", goal_id, state_dir);
}

fn runGoal(alloc: Allocator, tokens: [][]const u8, state_dir: []const u8, fs_iface: Fs, registry: *const skill_registry.SkillRegistry) !void {
    if (tokens.len < 2) {
        try emitErr("goal objective must not be empty");
        return;
    }
    var objective_parts = try std.ArrayList([]const u8).initCapacity(alloc, 0);
    defer objective_parts.deinit(alloc);
    var criterion: ?[]const u8 = null;
    var provider_override: ?[]const u8 = null;
    var verbose = false;
    var allow_push = false;
    var timeout_seconds: u64 = 600;
    var no_timeout_flag = false;
    var clean_tree = true;

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
        } else if (std.mem.eql(u8, t, "--allow-push")) {
            allow_push = true;
        } else if (std.mem.eql(u8, t, "--timeout")) {
            if (i + 1 >= tokens.len) {
                try emitErr("missing value for --timeout");
                return;
            }
            timeout_seconds = std.fmt.parseUnsigned(u64, tokens[i + 1], 10) catch {
                try emitErr("invalid --timeout value");
                return;
            };
            i += 1;
        } else if (std.mem.startsWith(u8, t, "--timeout=")) {
            timeout_seconds = std.fmt.parseUnsigned(u64, t["--timeout=".len..], 10) catch {
                try emitErr("invalid --timeout value");
                return;
            };
        } else if (std.mem.eql(u8, t, "--no-timeout")) {
            no_timeout_flag = true;
        } else if (std.mem.eql(u8, t, "--no-clean")) {
            clean_tree = false;
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
    var bt = BashTool.init(fs_iface, allow_push, if (no_timeout_flag) BashTool.no_timeout else timeout_seconds);
    const bash_t = bt.toTool();

    // Skills (FR-005, FR-006, FR-010): the skill tool and the system-prompt
    // section exist only when at least one skill was discovered — with zero
    // skills the goal path behaves exactly as before this feature.
    var st = SkillTool.init(registry);
    const skill_t = st.toTool();
    var tools_storage: [6]Tool = .{ read_t, edit_t, search_t, write_t, bash_t, undefined };
    var tools_len: usize = 5;
    var skills_listing: ?[]const u8 = null;
    defer if (skills_listing) |sl| alloc.free(sl);
    if (registry.list().len > 0) {
        tools_storage[5] = skill_t;
        tools_len = 6;
        skills_listing = skill_registry.listingText(alloc, registry) catch null;
    }
    const tools = tools_storage[0..tools_len];

    var repo_impl = FsGoalRepository.init(fs_iface, state_dir, SESSION_ID);
    const repo = repo_impl.toRepository();

    var ex = GoalExecutor{
        .alloc = alloc,
        .provider = prov,
        .tools = tools,
        .repo = repo,
        .fs = fs_iface,
        .dir = state_dir,
        .session_id = SESSION_ID,
        .verbose = verbose,
        .skills_listing = skills_listing,
        .clean_tree = clean_tree,
    };
    // FR-006: the job report is allocated inside the run (finalizeReport). Free it
    // on every exit path, including when ex.run() throws (the explicit free below
    // would otherwise be skipped and the buffer would leak).
    defer if (ex.report) |r| alloc.free(r);

    var goal = try Goal.init(alloc, objective, criterion, SESSION_ID);
    defer goal.deinit(alloc);

    // Spec 011: wire the Herdr state publisher. `buildStatePublisher` reads
    // HERDR_PANE_ID and builds a real reporter when present, or a null-reporter
    // publisher (screen markers + OSC only) when absent (FR-008).
    const stdout_writer = stdoutAnyWriter();
    var herdr_client_slot: ?herdr.HerdrHttpClient = null;
    ex.publisher = try buildStatePublisher(alloc, transport.toTransport(), std.posix.getenv("HERDR_PANE_ID"), goal.id, state_dir, &herdr_client_slot, stdout_writer);

    try emitStatus(.active);
    try ex.run(&goal);
    try emitStatus(goal.status);
    try emitSummary(&goal);

    // FR-006: report what changed, what was skipped, and whether a push happened.
    if (ex.report) |r| {
        try emit("job report:", .{});
        try emit("{s}", .{r});
    }
    const push_line = if (bt.push_occurred)
        "push: occurred"
    else if (bt.push_blocked)
        "push: blocked (not authorized — re-run with --allow-push)"
    else
        "push: not requested";
    try emit("  {s}", .{push_line});
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

const GoalCtx = struct { state_dir: []const u8, fs: Fs, registry: *const skill_registry.SkillRegistry };
const StopCtx = struct { state_dir: []const u8 };
const ProviderCtx = struct { state_dir: []const u8 };
const StatusCtx = struct { state_dir: []const u8, fs: Fs };
const GoalsCtx = struct { state_dir: []const u8, fs: Fs };
const SkillCtx = struct { registry: *const skill_registry.SkillRegistry };
const HelpCtx = struct {};

fn goalHandle(ctx_: *anyopaque, alloc: Allocator, intent: Intent) !Result {
    const self: *GoalCtx = @ptrCast(@alignCast(ctx_));
    var toks = try std.ArrayList([]const u8).initCapacity(alloc, 0);
    defer toks.deinit(alloc);
    try toks.append(alloc, "/goal");
    var it = std.mem.tokenizeScalar(u8, intent.args, ' ');
    while (it.next()) |t| try toks.append(alloc, t);
    runGoal(alloc, toks.items, self.state_dir, self.fs, self.registry) catch {};
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
fn skillHandle(ctx_: *anyopaque, alloc: Allocator, intent: Intent) !Result {
    const self: *SkillCtx = @ptrCast(@alignCast(ctx_));
    const out = skill_cmds.runSkillCommand(alloc, self.registry, intent.args) catch |e| {
        const msg = try std.fmt.allocPrint(alloc, "error: {s}", .{@errorName(e)});
        defer alloc.free(msg);
        try emit("{s}", .{msg});
        return Result{ .output = try alloc.dupe(u8, "") };
    };
    defer alloc.free(out);
    try emit("{s}", .{out});
    return Result{ .output = try alloc.dupe(u8, "") };
}
fn helpHandle(_: *anyopaque, _: Allocator, _: Intent) !Result {
    try emit("commands:", .{});
    try emit("  /goal <objective> [--criterion \"...\"] [--provider <name>] [--verbose] [--allow-push] [--timeout <s>|--no-timeout] [--no-clean]", .{});
    try emit("  /stop", .{});
    try emit("  /status", .{});
    try emit("  /goals", .{});
    try emit("  /provider [name]", .{});
    try emit("  /skill [list|show <name>]", .{});
    try emit("  /help", .{});
    return Result{ .output = try std.heap.page_allocator.dupe(u8, "") };
}

const goal_vtable = Handler.VTable{ .handle = goalHandle };
const stop_vtable = Handler.VTable{ .handle = stopHandle };
const provider_vtable = Handler.VTable{ .handle = providerHandle };
const status_vtable = Handler.VTable{ .handle = statusHandle };
const goals_vtable = Handler.VTable{ .handle = goalsHandle };
const skill_vtable = Handler.VTable{ .handle = skillHandle };
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
    try emit("  ziki /goal \"<objective>\" [--criterion \"<text>\"] [--provider <name>] [--verbose] [--allow-push] [--timeout <s>|--no-timeout] [--no-clean]", .{});
    try emit("  ziki /status", .{});
    try emit("  ziki /stop", .{});
    try emit("  ziki /goals", .{});
    try emit("  ziki /provider [name]", .{});
    try emit("  ziki /skill [list|show <name>]", .{});
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

    // Skills (FR-002): discover once per invocation; the registry is shared
    // by /goal (system-prompt listing + skill tool) and /skill (list/show).
    const skill_roots = skill_registry.defaultRoots(alloc, cwd) catch &[_][]const u8{};
    defer {
        for (skill_roots) |r| alloc.free(r);
        alloc.free(skill_roots);
    }
    var skill_reg = skill_registry.SkillRegistry.load(alloc, fs_iface, skill_roots) catch skill_registry.SkillRegistry.init(alloc);
    defer skill_reg.deinit();

    // Composition root: build the dispatcher and inject the handlers.
    var gh = GoalCtx{ .state_dir = state_dir, .fs = fs_iface, .registry = &skill_reg };
    var sh = StopCtx{ .state_dir = state_dir };
    var ph = ProviderCtx{ .state_dir = state_dir };
    var st = StatusCtx{ .state_dir = state_dir, .fs = fs_iface };
    var gl = GoalsCtx{ .state_dir = state_dir, .fs = fs_iface };
    var sk = SkillCtx{ .registry = &skill_reg };
    var hp = HelpCtx{};

    var dispatcher = Dispatcher.init(alloc);
    defer dispatcher.deinit();
    try dispatcher.register("goal", .{ .ctx = &gh, .vtable = &goal_vtable });
    try dispatcher.register("stop", .{ .ctx = &sh, .vtable = &stop_vtable });
    try dispatcher.register("provider", .{ .ctx = &ph, .vtable = &provider_vtable });
    try dispatcher.register("status", .{ .ctx = &st, .vtable = &status_vtable });
    try dispatcher.register("goals", .{ .ctx = &gl, .vtable = &goals_vtable });
    try dispatcher.register("skill", .{ .ctx = &sk, .vtable = &skill_vtable });
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

test "buildStatePublisher wires real reporter when HERDR_PANE_ID set, null otherwise (U19)" {
    const alloc = std.testing.allocator;
    var ft = FakeTransport.init(200, "");
    const t = ft.toTransport();

    var slot: ?herdr.HerdrHttpClient = null;
    var wbuf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&wbuf);
    const w = fbs.writer().any();
    const with = try buildStatePublisher(alloc, t, "pane-9", "goal-9", "/wd", &slot, w);
    try std.testing.expect(with.reporter != null);
    try std.testing.expect(slot != null); // client retained for the run's lifetime

    var slot2: ?herdr.HerdrHttpClient = null;
    var without = try buildStatePublisher(alloc, t, null, "goal-10", "/wd", &slot2, w);
    try std.testing.expect(without.reporter == null);
    try std.testing.expect(slot2 == null);

    // The no-reporter publisher is still safe to publish (degraded mode).
    var buf: [256]u8 = undefined;
    var fbs2 = std.io.fixedBufferStream(&buf);
    without.writer = fbs2.writer().any();
    without.publish(.working, null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..fbs2.pos], "[ziki-state: working]") != null);
}
