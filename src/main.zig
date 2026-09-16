const std = @import("std");
const Allocator = std.mem.Allocator;
const compat = @import("compat.zig");

const config = @import("config/config.zig");
const presets = @import("provider/presets.zig");
const HttpTransport = @import("provider/transport.zig").HttpTransport;
const RealFs = @import("fs/fs.zig").RealFs;
const Fs = @import("fs/fs.zig").Fs;
const GoalExecutor = @import("agent/executor.zig").GoalExecutor;
const state = @import("agent/state.zig");
const herdr = @import("agent/herdr.zig");
const socket_transport = @import("provider/transport_socket.zig");
const Transport = @import("provider/transport.zig").Transport;
const FakeTransport = @import("provider/transport.zig").FakeTransport;
const Goal = @import("goal/goal.zig").Goal;
const Status = @import("goal/goal.zig").Status;
const FsGoalRepository = @import("goal/repository.zig").FsGoalRepository;
const repository = @import("goal/repository.zig");
const stopmod = @import("agent/stop.zig");
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

/// Resolve this instance's session id (issue #20 bug 2): `ZIKI_SESSION_ID`
/// wins, then `HERDR_PANE_ID` (a herdr pane is exactly the per-window identity
/// of a side-by-side swarm), else the historical `"default"` so single-instance
/// behavior is unchanged. The returned slice is owned by `alloc`.
fn resolveSessionId(alloc: Allocator) ![]u8 {
    return resolveSessionIdFrom(alloc, compat.getenv("ZIKI_SESSION_ID"), compat.getenv("HERDR_PANE_ID")) catch |err| {
        if (err == error.InvalidSessionId) try emitErr("invalid session id — ZIKI_SESSION_ID / HERDR_PANE_ID must not contain path separators");
        return err;
    };
}

/// Pure variant so the precedence boundary is testable without mutating the
/// process environment. Empty strings count as unset.
fn resolveSessionIdFrom(alloc: Allocator, ziki_env: ?[]const u8, pane_env: ?[]const u8) ![]u8 {
    if (ziki_env) |z| {
        if (z.len > 0) return dupSessionId(alloc, z);
    }
    if (pane_env) |p| {
        if (p.len > 0) return dupSessionId(alloc, p);
    }
    return dupSessionId(alloc, "default");
}

/// Session ids become file-name fragments (`goal.<id>.json`, `stop.<id>`):
/// reject path separators so an id can never escape the state dir.
fn dupSessionId(alloc: Allocator, id: []const u8) ![]u8 {
    for (id) |ch| {
        if (ch == '/' or ch == '\\') return error.InvalidSessionId;
    }
    return alloc.dupe(u8, id);
}

fn emit(comptime fmt: []const u8, args: anytype) !void {
    const s = try std.fmt.allocPrint(std.heap.page_allocator, fmt ++ "\n", args);
    defer std.heap.page_allocator.free(s);
    try std.Io.File.stdout().writeStreamingAll(compat.io(), s);
}
fn emitErr(msg: []const u8) !void {
    const out = std.Io.File.stdout();
    const io = compat.io();
    try out.writeStreamingAll(io, "error: ");
    try out.writeStreamingAll(io, msg);
    try out.writeStreamingAll(io, "\n");
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

// ---------------------------------------------------------------------------
// Goal-run signal handling (spec 013 T13): SIGINT/SIGTERM during a goal run
// write the stop file so the loop aborts gracefully and saves state instead
// of dying mid-turn. The handler is async-signal-safe (open/write/close, raw
// _exit only). When no goal run is active it exits 130, restoring stock
// Ctrl-C behavior — a swallowed SIGINT would make the REPL uninterruptible
// after the first run.
// ---------------------------------------------------------------------------
var g_goal_stop_path: [512]u8 = undefined;
var g_goal_stop_len: usize = 0;
var g_goal_active = std.atomic.Value(bool).init(false);

fn goalSignalHandler(sig: std.c.SIG) callconv(.c) void {
    _ = sig;
    // 0.16: the Sigaction handler takes the system SIG enum; exit lives on
    // std.process now.
    if (!g_goal_active.load(.acquire)) std.process.exit(130); // no run active: default die
    if (g_goal_stop_len == 0 or g_goal_stop_len >= g_goal_stop_path.len) return;
    // Async-signal-safe: plain C open/close (std.posix.open is gone in 0.16).
    g_goal_stop_path[g_goal_stop_len] = 0;
    const path_z: [*:0]const u8 = @ptrCast(&g_goal_stop_path);
    const fd = std.c.open(path_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    if (fd >= 0) _ = std.c.close(fd);
}

fn armGoalSignals(stop_path: []const u8) void {
    if (stop_path.len > g_goal_stop_path.len) return;
    @memcpy(g_goal_stop_path[0..stop_path.len], stop_path);
    g_goal_stop_len = stop_path.len;
    g_goal_active.store(true, .release);
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = goalSignalHandler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
    std.posix.sigaction(std.posix.SIG.TERM, &act, null);
}

fn disarmGoalSignals() void {
    g_goal_active.store(false, .release);
}

/// Classification of a resume request (spec 013 T12/B17). Pure so the guards
/// are testable without a live store.
pub const ResumeGuard = enum { ok, no_such_goal, terminal };
pub fn resumeGuard(want_id: ?[]const u8, stored_id: []const u8, status: Status) ResumeGuard {
    if (want_id) |w| {
        if (!std.mem.eql(u8, w, stored_id)) return .no_such_goal;
    }
    if (status.isTerminal()) return .terminal;
    return .ok;
}

fn sessionProviderPath(alloc: Allocator, state_dir: []const u8) ![]u8 {
    return std.fs.path.join(alloc, &.{ state_dir, "provider.txt" });
}
fn readSessionProvider(alloc: Allocator, state_dir: []const u8) !?[]const u8 {
    const p = try sessionProviderPath(alloc, state_dir);
    defer alloc.free(p);
    const raw = std.Io.Dir.cwd().readFileAlloc(compat.io(), p, alloc, .limited(256)) catch return null;
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
    try std.Io.Dir.cwd().writeFile(compat.io(), .{ .sub_path = p, .data = name });
}

// ---------------------------------------------------------------------------
// Command handlers. Each wraps the existing logic behind the Handler interface
// so the dispatcher stays command-agnostic (SC-005, DIP).
// ---------------------------------------------------------------------------

/// Sink that emits to stdout (fd 1). Used by the Herdr state publisher to
/// write the `[ziki-state: ...]` screen marker and OSC title (0.16 has no
/// AnyWriter; the publisher takes the codebase's `state.Sink` vtable).
fn stdoutSinkWriteFn(_: *anyopaque, bytes: []const u8) void {
    std.Io.File.stdout().writeStreamingAll(compat.io(), bytes) catch {};
}
var stdout_sink_ctx: u8 = 0;
fn stdoutSink() state.Sink {
    return .{ .ctx = &stdout_sink_ctx, .writeFn = stdoutSinkWriteFn };
}

/// Build the Herdr `StatePublisher` for a goal (spec 011, FR-008).
///
/// When `pane_id` is set, resolves the Herdr API URL, selects the transport by
/// its scheme (spec 012 FR-002: `unix://` → socket transport stored in
/// `herdr_socket_slot`, http(s) → the provider's HTTP transport, anything else
/// fails fast with a clear message, FR-007), builds a real `HerdrHttpClient`
/// reporter (stored in `herdr_client_slot`, which the caller owns and keeps
/// alive for the run) so Ziki pushes state to Herdr. When `pane_id` is null,
/// returns a publisher with `reporter = null`: it still emits the screen
/// marker + OSC title but never pushes (degraded mode).
fn buildStatePublisher(
    alloc: Allocator,
    transport: Transport,
    pane_id: ?[]const u8,
    goal_id: []const u8,
    state_dir: []const u8,
    herdr_client_slot: *?herdr.HerdrHttpClient,
    herdr_socket_slot: *?*socket_transport.SocketTransport,
    writer: state.Sink,
) !state.StatePublisher {
    var reporter: ?state.HerdrReporter = null;
    if (pane_id) |_| {
        const api_url = try herdr.resolveApiUrl(alloc);
        defer alloc.free(api_url);
        var t = transport;
        switch (socket_transport.selectByUrl(api_url)) {
            .socket => {
                const parts = socket_transport.splitUnixUrl(api_url) orelse {
                    try emitErr("invalid HERDR_API_URL — unix:// needs an absolute socket path: unix:///abs/path.sock[/api/route]");
                    return error.InvalidApiUrl;
                };
                // The /api/ marker is reserved for the request route: a socket
                // path containing it is ambiguous and would mis-route.
                if (!std.mem.eql(u8, parts.request_path, "/") and !std.mem.startsWith(u8, parts.request_path, "/api/v1/")) {
                    const msg = try std.fmt.allocPrint(alloc, "ambiguous HERDR_API_URL — unix:// socket path must not contain /api/ (reserved route marker): {s}", .{api_url});
                    defer alloc.free(msg);
                    try emitErr(msg);
                    return error.InvalidApiUrl;
                }
                const st = try alloc.create(socket_transport.SocketTransport);
                errdefer alloc.destroy(st);
                st.* = try socket_transport.SocketTransport.init(alloc, parts.socket_path);
                herdr_socket_slot.* = st;
                t = st.toTransport();
            },
            .http => {},
            .unsupported => {
                try emitErr("unsupported HERDR_API_URL scheme — use http://, https:// or unix:///abs/path.sock");
                return error.UnsupportedApiUrl;
            },
        }
        herdr_client_slot.* = try herdr.HerdrHttpClient.init(alloc, t, api_url);
        reporter = (herdr_client_slot.*).?.toReporter();
    }
    return state.StatePublisher.init(alloc, reporter, writer, pane_id orelse "", goal_id, state_dir);
}

fn runGoal(alloc: Allocator, tokens: [][]const u8, state_dir: []const u8, session_id: []const u8, fs_iface: Fs, registry: *const skill_registry.SkillRegistry) !void {
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
    var max_tokens: ?u64 = null;
    var max_turns: ?u32 = null;

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
        } else if (std.mem.eql(u8, t, "--max-tokens")) {
            if (i + 1 >= tokens.len) {
                try emitErr("missing value for --max-tokens");
                return;
            }
            max_tokens = std.fmt.parseUnsigned(u64, tokens[i + 1], 10) catch {
                try emitErr("invalid --max-tokens value");
                return;
            };
            i += 1;
        } else if (std.mem.startsWith(u8, t, "--max-tokens=")) {
            max_tokens = std.fmt.parseUnsigned(u64, t["--max-tokens=".len..], 10) catch {
                try emitErr("invalid --max-tokens value");
                return;
            };
        } else if (std.mem.eql(u8, t, "--max-turns")) {
            if (i + 1 >= tokens.len) {
                try emitErr("missing value for --max-turns");
                return;
            }
            max_turns = std.fmt.parseUnsigned(u32, tokens[i + 1], 10) catch {
                try emitErr("invalid --max-turns value");
                return;
            };
            i += 1;
        } else if (std.mem.startsWith(u8, t, "--max-turns=")) {
            max_turns = std.fmt.parseUnsigned(u32, t["--max-turns=".len..], 10) catch {
                try emitErr("invalid --max-turns value");
                return;
            };
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

    var repo_impl = FsGoalRepository.init(fs_iface, state_dir, session_id);
    const repo = repo_impl.toRepository();
    // Fresh goal start: drop any transcript left by an earlier goal in this
    // session so a later resume never replays a foreign conversation (FR-003).
    repo.clearHistory(alloc) catch {};

    // Mid-turn stop observation (spec 013): the file probe backs both the
    // executor and the Bash tool so `/stop`, SIGINT and SIGTERM all land.
    const stop_probe_path = try std.fmt.allocPrint(alloc, "{s}/stop.{s}", .{ state_dir, session_id });
    defer alloc.free(stop_probe_path);
    var probe_impl = stopmod.FsProbe.init(fs_iface, stop_probe_path);
    bt.stop = probe_impl.probe();

    var ex = GoalExecutor{
        .alloc = alloc,
        .provider = prov,
        .tools = tools,
        .repo = repo,
        .fs = fs_iface,
        .dir = state_dir,
        .session_id = session_id,
        .verbose = verbose,
        .skills_listing = skills_listing,
        .clean_tree = clean_tree,
        .stop = probe_impl.probe(),
    };
    // FR-006: the job report is allocated inside the run (finalizeReport). Free it
    // on every exit path, including when ex.run() throws (the explicit free below
    // would otherwise be skipped and the buffer would leak).
    defer if (ex.report) |r| alloc.free(r);

    var goal = try Goal.init(alloc, objective, criterion, session_id);
    defer goal.deinit(alloc);
    // Budgets (spec 013 FR-010): --timeout/--no-timeout set the goal's
    // wall-clock budget (matching the Bash per-command budget); --max-tokens
    // and --max-turns override the remaining caps.
    goal.budgets.max_seconds = if (no_timeout_flag) std.math.maxInt(u64) else timeout_seconds;
    if (max_tokens) |v| goal.budgets.max_tokens = v;
    if (max_turns) |v| goal.budgets.max_turns = v;

    // Spec 011: wire the Herdr state publisher. `buildStatePublisher` reads
    // HERDR_PANE_ID and builds a real reporter when present, or a null-reporter
    // publisher (screen markers + OSC only) when absent (FR-008).
    var herdr_client_slot: ?herdr.HerdrHttpClient = null;
    // The client owns its URL copy (issue #20 bug 1); free it when the run ends.
    defer if (herdr_client_slot) |*c| c.deinit();
    // Spec 012: a unix:// HERDR_API_URL swaps in a socket transport for the
    // run; it is heap-allocated because the client stores the vtable by value.
    var herdr_socket_slot: ?*socket_transport.SocketTransport = null;
    defer if (herdr_socket_slot) |sock| {
        sock.deinit();
        alloc.destroy(sock);
    };
    ex.publisher = try buildStatePublisher(alloc, transport.toTransport(), compat.getenv("HERDR_PANE_ID"), goal.id, state_dir, &herdr_client_slot, &herdr_socket_slot, stdoutSink());

    try emitStatus(.active);
    // Ctrl-C / SIGTERM during a goal run abort gracefully via the stop file.
    armGoalSignals(stop_probe_path);
    defer disarmGoalSignals();
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
    if (bt.aborted) try emit("  a run_command was aborted mid-run by /stop", .{});
}

fn runStop(alloc: Allocator, state_dir: []const u8, session_id: []const u8) !void {
    const p = try std.fmt.allocPrint(alloc, "{s}/stop.{s}", .{ state_dir, session_id });
    defer alloc.free(p);
    std.Io.Dir.cwd().writeFile(compat.io(), .{ .sub_path = p, .data = "" }) catch {
        try emitErr("could not write stop signal");
        return;
    };
    try emit("stop signal set; the active goal will abort on its next turn", .{});
}

/// `/resume [goal-id] [--provider <name>] [-v] [--allow-push] [--timeout <s>|--no-timeout] [--no-clean]`
/// (spec 013 T12): load the persisted goal + transcript from the store and
/// continue the loop where it stopped.
fn runResume(alloc: Allocator, tokens: [][]const u8, state_dir: []const u8, session_id: []const u8, fs_iface: Fs, registry: *const skill_registry.SkillRegistry) !void {
    var goal_id_arg: ?[]const u8 = null;
    var provider_override: ?[]const u8 = null;
    var verbose = false;
    var allow_push = false;
    var timeout_seconds: u64 = 600;
    var no_timeout_flag = false;
    var clean_tree = true;

    var i: usize = 1;
    while (i < tokens.len) : (i += 1) {
        const t = tokens[i];
        if (std.mem.eql(u8, t, "--provider")) {
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
            if (goal_id_arg != null) {
                try emitErr("resume takes at most one goal id");
                return;
            }
            goal_id_arg = t;
        }
    }

    // Load the persisted goal and apply the resume guards (B17).
    var repo_impl = FsGoalRepository.init(fs_iface, state_dir, session_id);
    const repo = repo_impl.toRepository();
    var goal = (repo.load(alloc) catch null) orelse {
        try emitErr("no goal to resume — start one with /goal");
        return;
    };
    defer goal.deinit(alloc);
    switch (resumeGuard(goal_id_arg, goal.id, goal.status)) {
        .no_such_goal => {
            const msg = try std.fmt.allocPrint(alloc, "no such goal in the store: {s}", .{goal_id_arg.?});
            defer alloc.free(msg);
            try emitErr(msg);
            return;
        },
        .terminal => {
            const msg = try std.fmt.allocPrint(alloc, "goal already {s} — nothing to resume", .{goal.status.jsonString()});
            defer alloc.free(msg);
            try emitErr(msg);
            return;
        },
        .ok => {},
    }

    // Provider selection mirrors /goal.
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

    // Load the persisted transcript (missing/corrupt/foreign → fresh talk).
    const history: []const @import("provider/provider.zig").ChatMessage = repo.loadHistory(alloc, goal.id) catch null orelse &[_]@import("provider/provider.zig").ChatMessage{};
    defer if (history.len > 0) repository.freeHistory(alloc, @constCast(history));

    // Mid-turn stop observation (spec 013): same wiring as /goal.
    const stop_probe_path = try std.fmt.allocPrint(alloc, "{s}/stop.{s}", .{ state_dir, session_id });
    defer alloc.free(stop_probe_path);
    var probe_impl = stopmod.FsProbe.init(fs_iface, stop_probe_path);
    bt.stop = probe_impl.probe();

    var ex = GoalExecutor{
        .alloc = alloc,
        .provider = prov,
        .tools = tools,
        .repo = repo,
        .fs = fs_iface,
        .dir = state_dir,
        .session_id = session_id,
        .verbose = verbose,
        .skills_listing = skills_listing,
        .clean_tree = clean_tree,
        .stop = probe_impl.probe(),
    };
    defer if (ex.report) |r| alloc.free(r);

    // Time budget on resume: the persisted counter is the carry; a re-specified
    // --timeout widens/tightens the total wall clock from here on.
    goal.budgets.max_seconds = if (no_timeout_flag) std.math.maxInt(u64) else timeout_seconds;
    goal.status = .active;
    alloc.free(goal.progress);
    goal.progress = try alloc.dupe(u8, "resumed");
    goal.updated_at = @intCast(std.Io.Clock.real.now(compat.io()).toSeconds());

    try emit("resuming goal {s}: {s}", .{ goal.id, goal.objective });
    try emit("  turns: {d}/{d}  tokens: {d}  elapsed: {d}s", .{ goal.used.turns, goal.budgets.max_turns, goal.used.tokens, goal.used.seconds });
    try emitStatus(.active);
    armGoalSignals(stop_probe_path);
    defer disarmGoalSignals();
    try ex.runWithHistory(&goal, history);
    try emitStatus(goal.status);
    try emitSummary(&goal);

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
    if (bt.aborted) try emit("  a run_command was aborted mid-run by /stop", .{});
}

fn runStatus(alloc: Allocator, state_dir: []const u8, session_id: []const u8, fs_iface: Fs) !void {
    var repo_impl = FsGoalRepository.init(fs_iface, state_dir, session_id);
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

fn runGoals(alloc: Allocator, state_dir: []const u8, session_id: []const u8, fs_iface: Fs) !void {
    var repo_impl = FsGoalRepository.init(fs_iface, state_dir, session_id);
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

const GoalCtx = struct { state_dir: []const u8, session_id: []const u8, fs: Fs, registry: *const skill_registry.SkillRegistry };
const StopCtx = struct { state_dir: []const u8, session_id: []const u8 };
const ResumeCtx = struct { state_dir: []const u8, session_id: []const u8, fs: Fs, registry: *const skill_registry.SkillRegistry };
const ProviderCtx = struct { state_dir: []const u8 };
const StatusCtx = struct { state_dir: []const u8, session_id: []const u8, fs: Fs };
const GoalsCtx = struct { state_dir: []const u8, session_id: []const u8, fs: Fs };
const SkillCtx = struct { registry: *const skill_registry.SkillRegistry };
const HelpCtx = struct {};

fn goalHandle(ctx_: *anyopaque, alloc: Allocator, intent: Intent) !Result {
    const self: *GoalCtx = @ptrCast(@alignCast(ctx_));
    var toks = try std.ArrayList([]const u8).initCapacity(alloc, 0);
    defer toks.deinit(alloc);
    try toks.append(alloc, "/goal");
    var it = std.mem.tokenizeScalar(u8, intent.args, ' ');
    while (it.next()) |t| try toks.append(alloc, t);
    runGoal(alloc, toks.items, self.state_dir, self.session_id, self.fs, self.registry) catch {};
    return Result{ .output = try alloc.dupe(u8, "") };
}
fn stopHandle(ctx_: *anyopaque, alloc: Allocator, intent: Intent) !Result {
    const self: *StopCtx = @ptrCast(@alignCast(ctx_));
    _ = intent;
    runStop(alloc, self.state_dir, self.session_id) catch {};
    return Result{ .output = try alloc.dupe(u8, "") };
}
fn resumeHandle(ctx_: *anyopaque, alloc: Allocator, intent: Intent) !Result {
    const self: *ResumeCtx = @ptrCast(@alignCast(ctx_));
    var toks = try std.ArrayList([]const u8).initCapacity(alloc, 0);
    defer toks.deinit(alloc);
    try toks.append(alloc, "/resume");
    var it = std.mem.tokenizeScalar(u8, intent.args, ' ');
    while (it.next()) |t| try toks.append(alloc, t);
    runResume(alloc, toks.items, self.state_dir, self.session_id, self.fs, self.registry) catch {};
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
    runStatus(alloc, self.state_dir, self.session_id, self.fs) catch {};
    return Result{ .output = try alloc.dupe(u8, "") };
}
fn goalsHandle(ctx_: *anyopaque, alloc: Allocator, intent: Intent) !Result {
    const self: *GoalsCtx = @ptrCast(@alignCast(ctx_));
    _ = intent;
    runGoals(alloc, self.state_dir, self.session_id, self.fs) catch {};
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
    try emit("  /goal <objective> [--criterion \"...\"] [--provider <name>] [--verbose] [--allow-push] [--timeout <s>|--no-timeout] [--max-tokens <n>] [--max-turns <n>] [--no-clean]", .{});
    try emit("  /resume [goal-id] [--provider <name>] [--verbose] [--allow-push] [--timeout <s>|--no-timeout] [--no-clean]", .{});
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
const resume_vtable = Handler.VTable{ .handle = resumeHandle };
const provider_vtable = Handler.VTable{ .handle = providerHandle };
const status_vtable = Handler.VTable{ .handle = statusHandle };
const goals_vtable = Handler.VTable{ .handle = goalsHandle };
const skill_vtable = Handler.VTable{ .handle = skillHandle };
const help_vtable = Handler.VTable{ .handle = helpHandle };

// --- REPL output sink: stdout ---

var stdout_ctx: u8 = 0;
fn stdoutWrite(_: *anyopaque, data: []const u8) void {
    std.Io.File.stdout().writeStreamingAll(compat.io(), data) catch {};
}
const stdout_output = Output{ .ctx = &stdout_ctx, .vtable = &.{ .write = stdoutWrite } };

fn runRepl(alloc: Allocator, dispatcher: *Dispatcher) !void {
    var stdin_file = std.Io.File.stdin();
    var stdin_buf: [4096]u8 = undefined;
    var stdin_reader = stdin_file.readerStreaming(compat.io(), &stdin_buf);
    try Repl.run(alloc, &stdin_reader.interface, stdout_output, dispatcher, "ziki> ");
}

fn usage() !void {
    try emit("usage:", .{});
    try emit("  ziki /goal \"<objective>\" [--criterion \"<text>\"] [--provider <name>] [--verbose] [--allow-push] [--timeout <s>|--no-timeout] [--max-tokens <n>] [--max-turns <n>] [--no-clean]", .{});
    try emit("  ziki resume [goal-id] [--provider <name>] [--verbose] [--allow-push] [--timeout <s>|--no-timeout] [--no-clean]", .{});
    try emit("  ziki /status", .{});
    try emit("  ziki /stop", .{});
    try emit("  ziki /goals", .{});
    try emit("  ziki /provider [name]", .{});
    try emit("  ziki /skill [list|show <name>]", .{});
    try emit("  ziki            (interactive REPL)", .{});
}

pub fn main(env: std.process.Init) !void {
    // 0.16: start.zig hands us the process environment (Io + environ map) and
    // a leak-checked gpa; there is no GeneralPurposeAllocator to build here.
    compat.init(env);
    const alloc = env.gpa;

    var arg_list = try std.ArrayList([]const u8).initCapacity(alloc, 0);
    defer {
        for (arg_list.items) |a| alloc.free(a);
        arg_list.deinit(alloc);
    }
    var arg_it = std.process.Args.Iterator.initAllocator(env.minimal.args, alloc) catch std.process.Args.Iterator.init(env.minimal.args);
    defer arg_it.deinit();
    while (arg_it.next()) |a| try arg_list.append(alloc, try alloc.dupe(u8, a));
    const args: []const []const u8 = arg_list.items;

    const cwd = try std.process.currentPathAlloc(compat.io(), alloc);
    defer alloc.free(cwd);
    const state_dir = try std.fs.path.join(alloc, &.{ cwd, ".ziki" });
    defer alloc.free(state_dir);
    std.Io.Dir.cwd().createDirPath(compat.io(), state_dir) catch {};

    // Issue #20 bug 2: per-window session identity, resolved once and shared
    // by the goal, stop, status, and goals commands.
    const session_id = try resolveSessionId(alloc);
    defer alloc.free(session_id);

    var realfs_impl = RealFs.init(cwd);
    const fs_iface = realfs_impl.toFs();

    // Skills (FR-002): discover once per invocation; the registry is shared
    // by /goal (system-prompt listing + skill tool) and /skill (list/show).
    // `defaultRoots` only fails on OutOfMemory. On that path fall back to an
    // empty, allocator-owned slice (never a comptime literal) so the `defer`
    // below always frees memory the allocator actually owns.
    const skill_roots = skill_registry.defaultRoots(alloc, cwd) catch try alloc.alloc([]const u8, 0);
    defer {
        for (skill_roots) |r| alloc.free(r);
        alloc.free(skill_roots);
    }
    var skill_reg = skill_registry.SkillRegistry.load(alloc, fs_iface, skill_roots) catch skill_registry.SkillRegistry.init(alloc);
    defer skill_reg.deinit();

    // Composition root: build the dispatcher and inject the handlers.
    var gh = GoalCtx{ .state_dir = state_dir, .session_id = session_id, .fs = fs_iface, .registry = &skill_reg };
    var sh = StopCtx{ .state_dir = state_dir, .session_id = session_id };
    var rh = ResumeCtx{ .state_dir = state_dir, .session_id = session_id, .fs = fs_iface, .registry = &skill_reg };
    var ph = ProviderCtx{ .state_dir = state_dir };
    var st = StatusCtx{ .state_dir = state_dir, .session_id = session_id, .fs = fs_iface };
    var gl = GoalsCtx{ .state_dir = state_dir, .session_id = session_id, .fs = fs_iface };
    var sk = SkillCtx{ .registry = &skill_reg };
    var hp = HelpCtx{};

    var dispatcher = Dispatcher.init(alloc);
    defer dispatcher.deinit();
    try dispatcher.register("goal", .{ .ctx = &gh, .vtable = &goal_vtable });
    try dispatcher.register("stop", .{ .ctx = &sh, .vtable = &stop_vtable });
    try dispatcher.register("resume", .{ .ctx = &rh, .vtable = &resume_vtable });
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
        // Bare `ziki resume [goal-id]` (spec 013 FR-001); anything else is usage.
        if (!std.mem.eql(u8, args[1], "resume")) {
            try usage();
            return;
        }
        const joined = try std.mem.join(alloc, " ", args[1..]);
        defer alloc.free(joined);
        const with_slash = try std.fmt.allocPrint(alloc, "/{s}", .{joined});
        defer alloc.free(with_slash);
        const intent = (try parser.parseLine(with_slash)) orelse {
            try emitErr("empty command");
            return;
        };
        const result = dispatcher.dispatch(alloc, intent) catch |e| Result{
            .output = try std.fmt.allocPrint(alloc, "error: {s}", .{@errorName(e)}),
        };
        if (result.output.len > 0) try emit("{s}", .{result.output});
        alloc.free(result.output);
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
    var sock_slot: ?*socket_transport.SocketTransport = null;
    var wbuf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&wbuf);
    var wsink = state.WriterSink{ .w = &w };
    const with = try buildStatePublisher(alloc, t, "pane-9", "goal-9", "/wd", &slot, &sock_slot, wsink.sink());
    try std.testing.expect(with.reporter != null);
    try std.testing.expect(slot != null); // client retained for the run's lifetime
    if (slot) |*c| c.deinit();
    if (sock_slot) |st| {
        st.deinit();
        alloc.destroy(st);
    }

    var slot2: ?herdr.HerdrHttpClient = null;
    var sock_slot2: ?*socket_transport.SocketTransport = null;
    var without = try buildStatePublisher(alloc, t, null, "goal-10", "/wd", &slot2, &sock_slot2, wsink.sink());
    try std.testing.expect(without.reporter == null);
    try std.testing.expect(slot2 == null);

    // The no-reporter publisher is still safe to publish (degraded mode).
    var buf: [256]u8 = undefined;
    var w2 = std.Io.Writer.fixed(&buf);
    var wsink2 = state.WriterSink{ .w = &w2 };
    without.writer = wsink2.sink();
    without.publish(.working, null);
    try std.testing.expect(std.mem.indexOf(u8, w2.buffered(), "[ziki-state: working]") != null);
}

test "resume guard classifications (B17)" {
    try std.testing.expect(resumeGuard(null, "goal-1", .active) == .ok);
    try std.testing.expect(resumeGuard("goal-1", "goal-1", .active) == .ok);
    try std.testing.expect(resumeGuard("goal-x", "goal-1", .active) == .no_such_goal);
    try std.testing.expect(resumeGuard(null, "goal-1", .completed) == .terminal);
    try std.testing.expect(resumeGuard(null, "goal-1", .blocked) == .terminal);
    try std.testing.expect(resumeGuard(null, "goal-1", .aborted) == .terminal);
}

// Issue #20 bug 2: the session id is resolved, never hard-coded.
test "resolveSessionIdFrom precedence: ZIKI_SESSION_ID > HERDR_PANE_ID > default (U1)" {
    const alloc = std.testing.allocator;
    // Explicit env wins.
    const a = try resolveSessionIdFrom(alloc, "win-7", "pane-9");
    defer alloc.free(a);
    try std.testing.expectEqualStrings("win-7", a);
    // Pane id is the per-window identity when no explicit session is set.
    const b = try resolveSessionIdFrom(alloc, null, "pane-9");
    defer alloc.free(b);
    try std.testing.expectEqualStrings("pane-9", b);
    // Neither set: the historical default (backward compatible).
    const c = try resolveSessionIdFrom(alloc, null, null);
    defer alloc.free(c);
    try std.testing.expectEqualStrings("default", c);
    // Empty strings are treated as unset (a blank env var must not isolate goals
    // under an empty id).
    const d = try resolveSessionIdFrom(alloc, "", "");
    defer alloc.free(d);
    try std.testing.expectEqualStrings("default", d);
    const e = try resolveSessionIdFrom(alloc, "", "pane-2");
    defer alloc.free(e);
    try std.testing.expectEqualStrings("pane-2", e);
}

test "resolved session ids isolate goal repositories (A2)" {
    const alloc = std.testing.allocator;
    var fake = @import("fs/fs.zig").FakeFs.init(alloc, "/wd");
    defer fake.deinit();

    // Two side-by-side windows: ids resolved from different pane envs.
    const id_a = try resolveSessionIdFrom(alloc, null, "pane-1");
    defer alloc.free(id_a);
    const id_b = try resolveSessionIdFrom(alloc, null, "pane-2");
    defer alloc.free(id_b);
    try std.testing.expect(!std.mem.eql(u8, id_a, id_b));

    var repo_a_impl = FsGoalRepository.init(fake.toFs(), ".ziki", id_a);
    const repo_a = repo_a_impl.toRepository();
    var repo_b_impl = FsGoalRepository.init(fake.toFs(), ".ziki", id_b);
    const repo_b = repo_b_impl.toRepository();

    var g = try Goal.init(alloc, "window A objective", null, id_a);
    defer g.deinit(alloc);
    try repo_a.save(alloc, g);

    // A persists its own goal; B sees nothing (per-window isolation).
    var loaded_a = (try repo_a.load(alloc)).?;
    defer loaded_a.deinit(alloc);
    try std.testing.expectEqualStrings("window A objective", loaded_a.objective);
    try std.testing.expect((try repo_b.load(alloc)) == null);

    // Isolation is on-disk: each session has its own state file.
    const fs_iface = fake.toFs();
    try std.testing.expect(fs_iface.exists(".ziki/goal.pane-1.json"));
    try std.testing.expect(!fs_iface.exists(".ziki/goal.pane-2.json"));
    try std.testing.expect(!fs_iface.exists(".ziki/goal.default.json"));
}
