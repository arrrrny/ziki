const std = @import("std");
const Allocator = std.mem.Allocator;
const state = @import("state.zig");
const provider = @import("../provider/provider.zig");
const Tool = @import("../tool/tool.zig").Tool;
const ToolResult = @import("../tool/tool.zig").ToolResult;
const Goal = @import("../goal/goal.zig").Goal;
const GoalRepository = @import("../goal/repository.zig").GoalRepository;
const Fs = @import("../fs/fs.zig").Fs;
const StopProbe = @import("stop.zig").StopProbe;

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
    /// Preformatted skill listing (FR-005): one "- name: description" line
    /// per skill, appended to the system prompt. Null or empty means no
    /// skills were discovered and the prompt is byte-identical to the
    /// pre-feature behavior (FR-010). Built by the composition root from the
    /// SkillRegistry — the executor stays ignorant of the skill domain (ISP).
    skills_listing: ?[]const u8 = null,
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
    /// Mid-turn stop observation (spec 013 D5). When null the loop falls back
    /// to the stop-file probe built from `dir`/`session_id` (the `/stop`
    /// contract), so existing behavior is unchanged.
    stop: ?StopProbe = null,
    /// Compaction window (spec 013 D3): how many recent messages are retained
    /// when the conversation is compacted. The system prompt and the original
    /// goal message are always retained in addition.
    retain_recent: usize = 8,
    /// Number of compactions performed this run (observable; reported).
    compactions: u32 = 0,
    /// Wall-clock accounting (spec 013 D4): `goal.used.seconds` value captured
    /// at run start (persisted carry from earlier runs) and this run's start.
    carried_seconds: u64 = 0,
    run_start_ms: i64 = 0,
    /// Cached stop-file path for the default probe (owned by `alloc`).
    stop_path: ?[]const u8 = null,

    /// Print a diagnostic line to stdout (only when verbose). Used so an
    /// autonomous run is observable instead of appearing to "do nothing".
    fn logLine(alloc: Allocator, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.allocPrint(alloc, fmt ++ "\n", args) catch return;
        defer alloc.free(s);
        std.fs.File.stdout().writeAll(s) catch {};
    }

    /// Owns `goal.progress` as a heap slice: frees the previous value before
    /// storing the new one so the executor never leaks between turns.
    fn setProgress(self: *GoalExecutor, goal: *Goal, p: []const u8) !void {
        self.alloc.free(goal.progress);
        goal.progress = try self.alloc.dupe(u8, p);
    }

    /// Mid-turn stop observation (spec 013 D5). An injected probe wins; the
    /// fallback is the `/stop` signal file of this session.
    fn stopRequested(self: *GoalExecutor) bool {
        if (self.stop) |p| return p.isStop();
        if (self.stop_path) |p| return self.fs.exists(p);
        return false;
    }

    /// Best-effort transcript persistence after each turn (spec 013 D1):
    /// resume replays this; a failed save degrades the next resume to a fresh
    /// conversation, so it must never fail the run.
    fn saveHistorySafe(self: *GoalExecutor, goal_id: []const u8, messages: []const provider.ChatMessage) void {
        self.repo.saveHistory(self.alloc, goal_id, messages) catch |e| {
            if (self.verbose) logLine(self.alloc, "verbose: history save failed: {s}", .{@errorName(e)});
        };
    }

    /// Move the goal into a terminal state: status + progress + publisher +
    /// persist. Conversation history is cleared for terminal goals so the
    /// session's next goal never replays a foreign transcript.
    fn finish(self: *GoalExecutor, goal: *Goal, status: @import("../goal/goal.zig").Status, progress: []const u8, publisher_msg: ?[]const u8, skip: ?[]const u8) !void {
        goal.status = status;
        if (self.publisher != null) {
            self.publisher.?.publish(if (status == .blocked) .blocked else .idle, publisher_msg);
        }
        try self.setProgress(goal, progress);
        if (skip) |s| try self.addSkip(s);
        try self.repo.save(self.alloc, goal.*);
        self.repo.clearHistory(self.alloc) catch {};
    }

    /// Token estimate for a message list (spec 013 D2 fallback): content and
    /// tool-call JSON bytes divided by 4, plus a small per-message overhead.
    fn estimateTokens(messages: []const provider.ChatMessage) u64 {
        var bytes: u64 = 0;
        for (messages) |m| {
            bytes += m.content.len + 8;
            if (m.tool_calls) |tcs| {
                for (tcs) |tc| bytes += tc.arguments_json.len + tc.name.len + 16;
            }
        }
        return bytes / 4;
    }

    fn dupeMessageInto(a: Allocator, m: provider.ChatMessage) !provider.ChatMessage {
        var tcs: ?[]provider.ToolCall = null;
        if (m.tool_calls) |src| {
            const owned = try a.alloc(provider.ToolCall, src.len);
            for (src, 0..) |tc, i| {
                owned[i] = .{
                    .id = try a.dupe(u8, tc.id),
                    .name = try a.dupe(u8, tc.name),
                    .arguments_json = try a.dupe(u8, tc.arguments_json),
                };
            }
            tcs = owned;
        }
        return .{
            .role = m.role,
            .content = try a.dupe(u8, m.content),
            .tool_calls = tcs,
            .tool_call_id = if (m.tool_call_id) |id| try a.dupe(u8, id) else null,
        };
    }

    fn dupeResponseInto(a: Allocator, r: provider.ChatResponse) !provider.ChatResponse {
        return .{
            .message = try dupeMessageInto(a, r.message),
            .finish_reason = r.finish_reason,
            .usage = r.usage,
        };
    }

    /// Compact the conversation (spec 013 D3): retain the system prompt, the
    /// original goal message, a compaction notice, and the most recent
    /// `retain_recent` messages (extended backwards so a tool result is never
    /// separated from its assistant tool_calls message). Rebuilds the list in
    /// a fresh arena and resets the old one so per-run memory stays bounded.
    /// Returns true when a compaction happened, false when nothing was
    /// trimmable (the caller then stops on the token budget).
    fn compact(self: *GoalExecutor, arena: *std.heap.ArenaAllocator, messages: *std.ArrayList(provider.ChatMessage), goal: *Goal) !bool {
        const msgs = messages.items;
        if (msgs.len < 3) return false; // system + goal + at most one more: nothing trimmable
        // First retained index: keep the last `retain_recent` messages, then
        // extend backwards over a tool-result run so pairs stay intact. After
        // a prior compaction the kept head is 3 messages (system, goal, and
        // the compaction notice), not 2 — a window landing on the notice can
        // only re-drop what the rebuild re-adds, yielding nothing.
        const head: usize = if (self.compactions > 0) 3 else 2;
        var start = msgs.len - @min(self.retain_recent, msgs.len - head);
        while (start > head and msgs[start].role == .tool) start -= 1;
        if (start <= head) return false; // nothing between the kept head and the window

        var dropped_tokens: u64 = 0;
        for (msgs[head..start]) |m| {
            dropped_tokens += estimateTokens(&[_]provider.ChatMessage{m});
        }
        if (dropped_tokens < 64) return false; // near-zero yield: cannot relieve the budget

        var new_arena = std.heap.ArenaAllocator.init(self.alloc);
        errdefer new_arena.deinit();
        const na = new_arena.allocator();
        var new_msgs = try std.ArrayList(provider.ChatMessage).initCapacity(na, 0);
        try new_msgs.append(na, try dupeMessageInto(na, msgs[0]));
        try new_msgs.append(na, try dupeMessageInto(na, msgs[1]));
        try new_msgs.append(na, .{ .role = .user, .content = try na.dupe(u8, "[system note: earlier conversation turns were compacted to stay within the token budget]") });
        for (msgs[start..]) |m| {
            try new_msgs.append(na, try dupeMessageInto(na, m));
        }

        arena.deinit();
        arena.* = new_arena;
        messages.* = new_msgs;
        self.compactions += 1;
        goal.used.tokens -= @min(dropped_tokens, goal.used.tokens);
        try self.addSkip("context compacted: earlier turns trimmed to stay within the token budget");
        if (self.verbose) logLine(self.alloc, "verbose: compacted conversation to {d} messages", .{messages.items.len});
        return true;
    }

    /// One provider completion with mid-I/O stop observation (spec 013 D5/D9).
    ///
    /// The call runs on a worker thread with a dedicated arena holding a deep
    /// copy of the request; the caller polls the stop probe every 50 ms. When
    /// the probe fires, the in-flight call is abandoned (bounded grace), any
    /// late response is discarded, and `.aborted` is returned — the abort wins
    /// over a concurrent provider response (spec 006 edge case). Retries keep
    /// the 3-attempt/200 ms backoff of the plain loop, with every sleep and
    /// attempt boundary probe-checked.
    const Interruptible = union(enum) {
        resp: provider.ChatResponse,
        aborted: void,
    };

    const IoState = struct {
        exec: *GoalExecutor,
        req: provider.CompletionRequest,
        arena: *std.heap.ArenaAllocator,
        resp: ?provider.ChatResponse = null,
        err: ?anyerror = null,
        done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    };

    fn ioWorker(io: *IoState) void {
        const ia = io.arena.allocator();
        if (io.exec.provider.complete(ia, io.req)) |r| {
            io.resp = r;
        } else |e| {
            io.err = e;
        }
        io.done.store(true, .release);
    }

    fn completeInterruptible(self: *GoalExecutor, a: Allocator, req: provider.CompletionRequest) !Interruptible {
        const max_attempts: u32 = 3;
        const poll_ms: u64 = 50;
        const grace_ms: u64 = 2000;
        var attempt: u32 = 0;
        while (attempt < max_attempts) : (attempt += 1) {
            if (self.stopRequested()) return .aborted;

            const arena = try std.heap.page_allocator.create(std.heap.ArenaAllocator);
            arena.* = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            // Deep-copy the request into the worker arena so an abandoned
            // worker never reads memory owned by the caller's run arena.
            const owned_req = blk: {
                const wa = arena.allocator();
                const msgs = try wa.alloc(provider.ChatMessage, req.messages.len);
                for (req.messages, 0..) |m, i| msgs[i] = try dupeMessageInto(wa, m);
                const specs = try wa.alloc(provider.ToolSpec, req.tools.len);
                for (req.tools, 0..) |t, i| {
                    specs[i] = .{
                        .name = try wa.dupe(u8, t.name),
                        .description = try wa.dupe(u8, t.description),
                        .parameters_json_schema = try wa.dupe(u8, t.parameters_json_schema),
                    };
                }
                break :blk provider.CompletionRequest{ .messages = msgs, .tools = specs };
            };

            // Heap-allocated so the detached-abort path stays memory-safe: a
            // stack local would escape scope when the grace window expires and
            // the worker (still holding the pointer) later writes `io.resp` /
            // `io.err` / `io.done` into a popped frame.
            const io = try std.heap.page_allocator.create(IoState);
            io.* = .{ .exec = self, .req = owned_req, .arena = arena };
            const thread = std.Thread.spawn(.{}, ioWorker, .{io}) catch |e| {
                arena.deinit();
                std.heap.page_allocator.destroy(arena);
                std.heap.page_allocator.destroy(io);
                return e;
            };
            var stopped = false;
            while (!io.done.load(.acquire)) {
                if (self.stopRequested()) {
                    stopped = true;
                    break;
                }
                std.Thread.sleep(poll_ms * std.time.ns_per_ms);
            }
            if (!io.done.load(.acquire)) {
                // Abort grace: give the in-flight call a short window to finish
                // so the common case joins cleanly; a genuinely hung call is
                // detached (its arena is deliberately leaked — bounded KBs) and
                // dies with the process. Socket-level cancel is out of scope.
                var waited: u64 = 0;
                while (!io.done.load(.acquire) and waited < grace_ms) {
                    std.Thread.sleep(poll_ms * std.time.ns_per_ms);
                    waited += poll_ms;
                }
            }
            if (io.done.load(.acquire)) {
                thread.join();
                defer {
                    arena.deinit();
                    std.heap.page_allocator.destroy(arena);
                    std.heap.page_allocator.destroy(io);
                }
                if (stopped or self.stopRequested()) return .aborted; // abort wins: discard
                if (io.err) |e| {
                    if (attempt + 1 == max_attempts) return e;
                    var slept: u64 = 0;
                    while (slept < 200) : (slept += poll_ms) {
                        if (self.stopRequested()) return .aborted;
                        std.Thread.sleep(poll_ms * std.time.ns_per_ms);
                    }
                    continue;
                }
                return .{ .resp = try dupeResponseInto(a, io.resp.?) };
            }
            thread.detach();
            // The detached worker still owns `io` and its arena; both are
            // deliberately leaked (bounded KBs) and die with the process —
            // freeing them here would race the worker's final writes.
            return .aborted;
        }
        unreachable;
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
        if (self.skills_listing) |listing| {
            if (listing.len > 0) {
                try sb.writer(self.alloc).writeAll(
                    \\Skills you can consult — use the skill tool with the exact name to get its full instructions:
                    \\
                );
                try sb.writer(self.alloc).writeAll(listing);
            }
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

    /// Criterion verification. Returns `null` when the stop signal fired
    /// during the completion — the caller maps that to the graceful abort.
    /// Verification goes through the same interruptible completion as the
    /// main path so `/stop` is observed during its I/O too (it can be the
    /// longest single wait of the run). The completion is budget-accounted
    /// like any provider turn (review: verify calls were silently free).
    /// With `strict` the reply must be exactly `yes` (case-insensitive,
    /// whitespace-trimmed) to count as satisfied — used by the
    /// already-applied pre-check, where a chatty reply that merely contains
    /// "YES" must not complete the goal without any work.
    fn verify(self: *GoalExecutor, a: Allocator, goal: *Goal, messages: *std.ArrayList(provider.ChatMessage), criterion: []const u8, strict: bool) !?bool {
        try messages.append(a, .{ .role = .user, .content = try a.dupe(u8, try std.fmt.allocPrint(a, "Criterion: {s}\nIs it satisfied? Reply with exactly YES or NO.", .{criterion})) });
        const outcome = try self.completeInterruptible(a, .{ .messages = messages.items, .tools = &[0]provider.ToolSpec{} });
        const resp = switch (outcome) {
            .aborted => return null,
            .resp => |r| r,
        };
        goal.used.turns += 1;
        goal.used.tokens += if (resp.usage) |u| u.total() else estimateTokens(messages.items);
        const content = resp.message.content;
        if (self.verbose) logLine(self.alloc, "verbose: verify -> {s}", .{content});
        try messages.append(a, .{ .role = .assistant, .content = try a.dupe(u8, content) });
        const upper = try std.ascii.allocUpperString(a, content);
        defer a.free(upper);
        if (strict) {
            // Hold the call to its own prompt ("exactly YES or NO"): only a
            // bare yes short-circuits; anything else falls into the loop,
            // where end-of-run verification is the safety net.
            const trimmed = std.mem.trim(u8, upper, " \t\r\n");
            return std.mem.eql(u8, trimmed, "YES");
        }
        return std.mem.indexOf(u8, upper, "YES") != null;
    }

    /// Run the goal to a terminal state (completed / blocked / aborted),
    /// starting from a fresh conversation.
    pub fn run(self: *GoalExecutor, goal: *Goal) !void {
        return self.runWithHistory(goal, &[_]provider.ChatMessage{});
    }

    /// Run the goal, optionally seeded with a previously persisted transcript
    /// (spec 013: `ziki resume` loads turns from the store and continues).
    /// Budgets (turns, tokens, time), context compaction and mid-turn abort
    /// are enforced here; every turn persists goal state + transcript.
    pub fn runWithHistory(self: *GoalExecutor, goal: *Goal, history: []const provider.ChatMessage) !void {
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

        // Wall-clock budget carry (spec 013 D4) + cached default stop path.
        self.carried_seconds = goal.used.seconds;
        self.run_start_ms = std.time.milliTimestamp();
        if (self.stop_path) |p| self.alloc.free(p);
        self.stop_path = try std.fmt.allocPrint(self.alloc, "{s}/stop.{s}", .{ self.dir, self.session_id });
        defer {
            if (self.stop_path) |p| self.alloc.free(p);
            self.stop_path = null;
        }

        // The conversation lives in a swappable arena so compaction can reset
        // memory (spec 013 D3). `a` stays valid across swaps: it points at the
        // boxed arena, whose identity never changes.
        var arena_ptr = try self.alloc.create(std.heap.ArenaAllocator);
        arena_ptr.* = std.heap.ArenaAllocator.init(self.alloc);
        defer {
            arena_ptr.deinit();
            self.alloc.destroy(arena_ptr);
        }
        const a = arena_ptr.allocator();

        var messages = try std.ArrayList(provider.ChatMessage).initCapacity(a, 0);
        if (history.len > 0) {
            // Resume: replay the persisted transcript verbatim (SC-001).
            for (history) |m| {
                try messages.append(a, try dupeMessageInto(a, m));
            }
        } else {
            const sp = try self.systemPrompt();
            defer self.alloc.free(sp);
            try messages.append(a, .{ .role = .system, .content = try a.dupe(u8, sp) });
            const up = try self.userPrompt(goal);
            defer self.alloc.free(up);
            try messages.append(a, .{ .role = .user, .content = try a.dupe(u8, up) });
        }

        var verify_attempts: u32 = 0;
        // FR-001/FR-002: announce `working` the moment the loop becomes active.
        if (self.publisher != null) {
            self.publisher.?.publish(.working, null);
        }
        // Spec 016 (issue #19): already-applied detection — one cheap
        // verification call before any provider turn. Only for fresh goals
        // (a resumed transcript already reflects the work done so far).
        // Strict: the model has zero workspace observations here, so a bare
        // yes is required — anything chatty runs the normal loop (and the
        // call is budget-accounted like any turn).
        if (goal.criterion != null and history.len == 0) {
            if ((try self.verify(a, goal, &messages, goal.criterion.?, true)) orelse false) {
                try self.finish(goal, .completed, "already done: criterion satisfied before starting", "already satisfied", "criterion already satisfied — no work turns needed (1 pre-check call)");
                return;
            }
        }
        while (goal.status == .active) {
            // Stop signal (top of turn — the between-turns observation point).
            if (self.stopRequested()) {
                if (self.stop_path) |p| self.fs.remove(p) catch {};
                try self.finish(goal, .aborted, "aborted by user", "aborted by user", "job aborted by user");
                return;
            }
            // Time budget (spec 013 D4): persisted carry + this run's elapsed.
            const elapsed_ms: u64 = @intCast(@max(0, std.time.milliTimestamp() - self.run_start_ms));
            goal.used.seconds = self.carried_seconds + elapsed_ms / 1000;
            if (goal.used.seconds >= goal.budgets.max_seconds) {
                try self.finish(goal, .aborted, "aborted: time budget exceeded", "aborted: time budget exceeded", "aborted: time budget exceeded");
                return;
            }
            // Turn budget (unchanged behavior).
            if (goal.used.turns >= goal.budgets.max_turns) {
                try self.finish(goal, .aborted, "aborted: turn budget exceeded", "aborted: turn budget exceeded", "aborted: turn budget exceeded");
                return;
            }
            goal.used.turns += 1;

            if (self.verbose) logLine(self.alloc, "verbose: turn {d}: requesting model ({d} msgs)", .{ goal.used.turns, messages.items.len });

            const specs = try self.toolSpecs(a);
            const outcome = try self.completeInterruptible(a, .{ .messages = messages.items, .tools = specs });
            const resp = switch (outcome) {
                .aborted => {
                    // Abort wins: the in-flight (or late) response is discarded,
                    // nothing is appended, nothing executes (spec 006 FR-007).
                    if (self.stop_path) |p| self.fs.remove(p) catch {};
                    try self.finish(goal, .aborted, "aborted by user", "aborted by user", "job aborted by user");
                    return;
                },
                .resp => |r| r,
            };
            try messages.append(a, resp.message);
            // Token accounting (spec 013 D2): reported usage when the backend
            // supplies it, estimated conversation cost otherwise.
            goal.used.tokens += if (resp.usage) |u| u.total() else estimateTokens(messages.items);

            if (self.verbose) {
                if (resp.message.tool_calls) |tcs| {
                    for (tcs) |tc| logLine(self.alloc, "verbose: tool_call {s} {s}", .{ tc.name, tc.arguments_json });
                } else {
                    logLine(self.alloc, "verbose: model: {s}", .{resp.message.content});
                }
            }

            if (resp.message.tool_calls) |tcs| {
                for (tcs) |tc| {
                    // Mid-turn abort: never start work after the signal.
                    if (self.stopRequested()) {
                        if (self.stop_path) |p| self.fs.remove(p) catch {};
                        try self.finish(goal, .aborted, "aborted by user", "aborted by user", "job aborted by user");
                        return;
                    }
                    const res = try self.dispatch(a, tc);
                    if (self.verbose) logLine(self.alloc, "verbose: tool_result[{s}]: {s}", .{ tc.name, res.output });
                    try messages.append(a, .{
                        .role = .tool,
                        .content = try a.dupe(u8, res.output),
                        .tool_call_id = try a.dupe(u8, tc.id),
                    });
                    // Persist after every tool result: a crash mid-loop must
                    // not desync the store from side effects already on disk
                    // (resume replays what actually ran).
                    self.saveHistorySafe(goal.id, messages.items);
                    // A tool run (e.g. Bash) may have observed the stop signal
                    // mid-command: unwind immediately, no further dispatches.
                    if (self.stopRequested()) {
                        if (self.stop_path) |p| self.fs.remove(p) catch {};
                        try self.finish(goal, .aborted, "aborted by user", "aborted by user", "job aborted by user");
                        return;
                    }
                }
                const p = try std.fmt.allocPrint(self.alloc, "executed {d} tool call(s)", .{tcs.len});
                self.alloc.free(goal.progress);
                goal.progress = p;
                try self.repo.save(self.alloc, goal.*);
                self.saveHistorySafe(goal.id, messages.items);

                // Token budget (spec 013 D3): compact first, stop gracefully
                // when compaction cannot relieve the pressure.
                if (goal.used.tokens >= goal.budgets.max_tokens) {
                    const compacted = try self.compact(arena_ptr, &messages, goal);
                    if (!compacted) {
                        try self.finish(goal, .aborted, "aborted: token budget exceeded", "aborted: token budget exceeded", "aborted: token budget exceeded");
                        return;
                    }
                    try self.repo.save(self.alloc, goal.*);
                    self.saveHistorySafe(goal.id, messages.items);
                }
                continue;
            }

            if (goal.criterion) |crit| {
                const satisfied = (try self.verify(a, goal, &messages, crit, false)) orelse {
                    // Stop observed during verification I/O: same graceful
                    // abort as the main path.
                    if (self.stop_path) |p| self.fs.remove(p) catch {};
                    try self.finish(goal, .aborted, "aborted by user", "aborted by user", "job aborted by user");
                    return;
                };
                if (satisfied) {
                    try self.finish(goal, .completed, "completed: criterion satisfied", null, null);
                    return;
                }
                verify_attempts += 1;
                if (verify_attempts >= 3) {
                    try self.finish(goal, .blocked, "could not satisfy criterion after retries", "criterion not satisfied after retries", "completion criterion not satisfied after retries");
                    return;
                }
                self.saveHistorySafe(goal.id, messages.items);
                continue;
            }

            try self.finish(goal, .completed, "completed", null, null);
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
    // ChildProcess has no deinit() in this Zig version, so the pipe fds (and the
    // std.fs.File buffers wrapping them) leak when `child` leaves scope. Close
    // them explicitly on every return path.
    defer {
        if (child.stdout) |s| s.close();
        if (child.stderr) |e| e.close();
    }
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

test "system prompt appends the skills listing when provided (FR-005)" {
    const alloc = std.testing.allocator;
    const FsGoalRepository = @import("../goal/repository.zig").FsGoalRepository;
    var fake = @import("../fs/fs.zig").FakeFs.init(alloc, "/wd");
    defer fake.deinit();

    const ok = provider.ChatResponse{ .message = .{ .role = .assistant, .content = "done" } };
    var scripted = @import("../provider/fake.zig").FakeProvider.init(&.{ok});
    const fp = scripted.toProvider();

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
        .skills_listing = "- code-review: Review code for SOLID violations\n",
    };
    const sp = try ex.systemPrompt();
    defer alloc.free(sp);
    try std.testing.expect(std.mem.indexOf(u8, sp, "Skills you can consult") != null);
    try std.testing.expect(std.mem.indexOf(u8, sp, "- code-review: Review code for SOLID violations") != null);
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

test "system prompt is unchanged when no skills listing is set (FR-010)" {
    const alloc = std.testing.allocator;
    const FsGoalRepository = @import("../goal/repository.zig").FsGoalRepository;
    var fake = @import("../fs/fs.zig").FakeFs.init(alloc, "/wd");
    defer fake.deinit();

    const ok = provider.ChatResponse{ .message = .{ .role = .assistant, .content = "done" } };
    var scripted = @import("../provider/fake.zig").FakeProvider.init(&.{ok});
    const fp = scripted.toProvider();

    const tools = [_]Tool{};
    var repo_impl = FsGoalRepository.init(fake.toFs(), ".ziki", "sess1");
    const repo = repo_impl.toRepository();

    var with_listing: GoalExecutor = .{
        .alloc = alloc,
        .provider = fp,
        .tools = &tools,
        .repo = repo,
        .fs = fake.toFs(),
        .dir = ".ziki",
        .session_id = "sess1",
    };
    // Default: null listing -> no skills section at all.
    var without: GoalExecutor = .{
        .alloc = alloc,
        .provider = fp,
        .tools = &tools,
        .repo = repo,
        .fs = fake.toFs(),
        .dir = ".ziki",
        .session_id = "sess1",
    };
    with_listing.skills_listing = null;
    without.skills_listing = "";

    const a = try with_listing.systemPrompt();
    defer alloc.free(a);
    const b = try without.systemPrompt();
    defer alloc.free(b);
    try std.testing.expect(std.mem.indexOf(u8, a, "Skills you can consult") == null);
    try std.testing.expect(std.mem.indexOf(u8, b, "Skills you can consult") == null);
    try std.testing.expectEqualStrings(a, b);
}

// ---------------------------------------------------------------------------
// spec 013 tests: budgets, compaction, abort, resume seeding.
// ---------------------------------------------------------------------------

const fake13 = @import("../provider/fake.zig");
const S13FakeFs = @import("../fs/fs.zig").FakeFs;
const S13Repo = @import("../goal/repository.zig");
const stopmod = @import("stop.zig");

fn mkExecutor(alloc: Allocator, fp: provider.Provider, tools: []const Tool, fake: *S13FakeFs, session: []const u8) GoalExecutor {
    var repo_impl = S13Repo.FsGoalRepository.init(fake.toFs(), ".ziki", session);
    repo_impl.toRepository(); // keep vtable warm for the borrow below
    return GoalExecutor{
        .alloc = alloc,
        .provider = fp,
        .tools = tools,
        .repo = repo_impl.toRepository(),
        .fs = fake.toFs(),
        .dir = ".ziki",
        .session_id = session,
    };
}

test "compaction trims the middle and the run continues (B7/B8)" {
    const alloc = std.testing.allocator;
    var fake = S13FakeFs.init(alloc, "/wd");
    defer fake.deinit();

    const tcs = [_]provider.ToolCall{.{ .id = "c1", .name = "write_file", .arguments_json = "{\"path\":\"a.txt\",\"data\":\"" ++ "a" ** 200 ++ "\"}" }};
    const tcs2 = [_]provider.ToolCall{.{ .id = "c2", .name = "write_file", .arguments_json = "{\"path\":\"b.txt\",\"data\":\"" ++ "b" ** 200 ++ "\"}" }};
    const responses = [_]provider.ChatResponse{
        .{ .message = .{ .role = .assistant, .content = "", .tool_calls = &tcs }, .finish_reason = .tool_calls, .usage = .{ .prompt_tokens = 40, .completion_tokens = 0 } },
        .{ .message = .{ .role = .assistant, .content = "", .tool_calls = &tcs2 }, .finish_reason = .tool_calls, .usage = .{ .prompt_tokens = 40, .completion_tokens = 0 } },
        .{ .message = .{ .role = .assistant, .content = "done" }, .usage = .{ .prompt_tokens = 0, .completion_tokens = 1 } },
    };
    var fp = fake13.FakeProvider.init(&responses);
    var wt_impl = @import("../tool/write.zig").WriteTool.init(fake.toFs());
    const wt = wt_impl.toTool();
    const tools = [_]Tool{wt};

    var repo_impl = S13Repo.FsGoalRepository.init(fake.toFs(), ".ziki", "sess1");
    const repo = repo_impl.toRepository();
    var ex = GoalExecutor{
        .alloc = alloc,
        .provider = fp.toProvider(),
        .tools = &tools,
        .repo = repo,
        .fs = fake.toFs(),
        .dir = ".ziki",
        .session_id = "sess1",
        .retain_recent = 2,
    };
    var goal = try Goal.init(alloc, "create files", null, "sess1");
    defer goal.deinit(alloc);
    goal.budgets.max_tokens = 75;
    try ex.run(&goal);
    defer if (ex.report) |r| alloc.free(r);

    try std.testing.expectEqualStrings("done", responses[2].message.content); // sanity: script shape
    try std.testing.expect(goal.status == .completed);
    try std.testing.expectEqual(@as(u32, 1), ex.compactions);
    // Dropped-turn accounting reduced the counter below the raw sum (80+1).
    try std.testing.expect(goal.used.tokens < 81);
    try std.testing.expect(std.mem.indexOf(u8, ex.report.?, "context compacted") != null);
}

test "token budget with nothing trimmable stops gracefully (B9)" {
    const alloc = std.testing.allocator;
    var fake = S13FakeFs.init(alloc, "/wd");
    defer fake.deinit();

    const tcs = [_]provider.ToolCall{.{ .id = "c1", .name = "write_file", .arguments_json = "{\"path\":\"a.txt\",\"data\":\"aaaa\"}" }};
    const responses = [_]provider.ChatResponse{
        .{ .message = .{ .role = .assistant, .content = "", .tool_calls = &tcs }, .finish_reason = .tool_calls, .usage = .{ .prompt_tokens = 500, .completion_tokens = 0 } },
        .{ .message = .{ .role = .assistant, .content = "should never be requested" } },
    };
    var fp = fake13.FakeProvider.init(&responses);
    var wt_impl = @import("../tool/write.zig").WriteTool.init(fake.toFs());
    const wt = wt_impl.toTool();
    const tools = [_]Tool{wt};

    var repo_impl = S13Repo.FsGoalRepository.init(fake.toFs(), ".ziki", "sess1");
    const repo = repo_impl.toRepository();
    var ex = GoalExecutor{
        .alloc = alloc,
        .provider = fp.toProvider(),
        .tools = &tools,
        .repo = repo,
        .fs = fake.toFs(),
        .dir = ".ziki",
        .session_id = "sess1",
        .retain_recent = 2,
    };
    var goal = try Goal.init(alloc, "create files", null, "sess1");
    defer goal.deinit(alloc);
    goal.budgets.max_tokens = 75;
    try ex.run(&goal);
    defer if (ex.report) |r| alloc.free(r);

    try std.testing.expect(goal.status == .aborted);
    try std.testing.expectEqualStrings("aborted: token budget exceeded", goal.progress);
    // Status persisted.
    var loaded_impl = S13Repo.FsGoalRepository.init(fake.toFs(), ".ziki", "sess1");
    var loaded = (try loaded_impl.toRepository().load(alloc)).?;
    defer loaded.deinit(alloc);
    try std.testing.expect(loaded.status == .aborted);
}

test "second over-budget turn after a compaction stops gracefully when relief is trivial (B9)" {
    const alloc = std.testing.allocator;
    var fake = S13FakeFs.init(alloc, "/wd");
    defer fake.deinit();

    // Turn 1 carries enough content for the first compaction to yield real
    // relief (>= the trivial-yield threshold); turn 2's small pair leaves only
    // notice + small messages before the window, so a second compaction can
    // never relieve and the run must stop gracefully instead of looping
    // notice-only compactions every turn.
    const tcs = [_]provider.ToolCall{.{ .id = "c1", .name = "write_file", .arguments_json = "{\"path\":\"a.txt\",\"data\":\"" ++ "a" ** 200 ++ "\"}" }};
    const tcs2 = [_]provider.ToolCall{.{ .id = "c2", .name = "write_file", .arguments_json = "{\"path\":\"b.txt\",\"data\":\"bb\"}" }};
    const tcs3 = [_]provider.ToolCall{.{ .id = "c3", .name = "write_file", .arguments_json = "{\"path\":\"c.txt\",\"data\":\"cc\"}" }};
    const responses = [_]provider.ChatResponse{
        .{ .message = .{ .role = .assistant, .content = "", .tool_calls = &tcs }, .finish_reason = .tool_calls, .usage = .{ .prompt_tokens = 40, .completion_tokens = 0 } },
        .{ .message = .{ .role = .assistant, .content = "", .tool_calls = &tcs2 }, .finish_reason = .tool_calls, .usage = .{ .prompt_tokens = 40, .completion_tokens = 0 } },
        .{ .message = .{ .role = .assistant, .content = "", .tool_calls = &tcs3 }, .finish_reason = .tool_calls, .usage = .{ .prompt_tokens = 500, .completion_tokens = 0 } },
        .{ .message = .{ .role = .assistant, .content = "should never be requested" } },
    };
    var fp = fake13.FakeProvider.init(&responses);
    var wt_impl = @import("../tool/write.zig").WriteTool.init(fake.toFs());
    const wt = wt_impl.toTool();
    const tools = [_]Tool{wt};

    var repo_impl = S13Repo.FsGoalRepository.init(fake.toFs(), ".ziki", "sess1");
    const repo = repo_impl.toRepository();
    var ex = GoalExecutor{
        .alloc = alloc,
        .provider = fp.toProvider(),
        .tools = &tools,
        .repo = repo,
        .fs = fake.toFs(),
        .dir = ".ziki",
        .session_id = "sess1",
        .retain_recent = 2,
    };
    var goal = try Goal.init(alloc, "create files", null, "sess1");
    defer goal.deinit(alloc);
    goal.budgets.max_tokens = 75;
    try ex.run(&goal);
    defer if (ex.report) |r| alloc.free(r);

    try std.testing.expect(goal.status == .aborted);
    try std.testing.expectEqualStrings("aborted: token budget exceeded", goal.progress);
    try std.testing.expectEqual(@as(u32, 1), ex.compactions); // no no-op second compaction
    try std.testing.expectEqual(@as(usize, 3), fp.idx); // the 4th response was never requested
}

test "provider-reported usage is summed; estimate used when absent (B10)" {
    const alloc = std.testing.allocator;
    var fake = S13FakeFs.init(alloc, "/wd");
    defer fake.deinit();

    const ok = provider.ChatResponse{ .message = .{ .role = .assistant, .content = "done" }, .usage = .{ .prompt_tokens = 5, .completion_tokens = 7 } };
    var fp = fake13.FakeProvider.init(&.{ok});
    const tools = [_]Tool{};
    var repo_impl = S13Repo.FsGoalRepository.init(fake.toFs(), ".ziki", "sess1");
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
    var goal = try Goal.init(alloc, "do something", null, "sess1");
    defer goal.deinit(alloc);
    try ex.run(&goal);
    defer if (ex.report) |r| alloc.free(r);
    try std.testing.expectEqual(@as(u64, 12), goal.used.tokens);

    // Estimated path: no usage reported -> conversation bytes/4.
    const ok2 = provider.ChatResponse{ .message = .{ .role = .assistant, .content = "done" } };
    var fp2 = fake13.FakeProvider.init(&.{ok2});
    var ex2 = GoalExecutor{
        .alloc = alloc,
        .provider = fp2.toProvider(),
        .tools = &tools,
        .repo = repo,
        .fs = fake.toFs(),
        .dir = ".ziki",
        .session_id = "sess1",
    };
    var goal2 = try Goal.init(alloc, "do something", null, "sess1");
    defer goal2.deinit(alloc);
    try ex2.run(&goal2);
    defer if (ex2.report) |r| alloc.free(r);
    try std.testing.expect(goal2.used.tokens > 0);
    try std.testing.expect(goal2.used.tokens != 12);
}

test "time budget already exhausted stops before any provider call (B11)" {
    const alloc = std.testing.allocator;
    var fake = S13FakeFs.init(alloc, "/wd");
    defer fake.deinit();

    const ok = provider.ChatResponse{ .message = .{ .role = .assistant, .content = "nope" } };
    var fp = fake13.FakeProvider.init(&.{ok});
    const tools = [_]Tool{};
    var repo_impl = S13Repo.FsGoalRepository.init(fake.toFs(), ".ziki", "sess1");
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
    var goal = try Goal.init(alloc, "do something", null, "sess1");
    defer goal.deinit(alloc);
    goal.budgets.max_seconds = 0;
    try ex.run(&goal);
    defer if (ex.report) |r| alloc.free(r);

    try std.testing.expect(goal.status == .aborted);
    try std.testing.expectEqualStrings("aborted: time budget exceeded", goal.progress);
    try std.testing.expectEqual(@as(usize, 0), fp.idx); // no scripted response consumed
}

/// Test tool that raises a stop probe when executed.
const RaiseProbeTool = struct {
    probe: *stopmod.AtomicProbe,
    calls: usize = 0,

    fn toTool(self: *RaiseProbeTool) Tool {
        return .{ .ctx = self, .vtable = &vtable };
    }
    const vtable = Tool.VTable{ .execute = execute, .schema = schema, .name = name };
    fn name(_: *anyopaque) []const u8 {
        return "raise_stop";
    }
    fn schema(_: *anyopaque) provider.ToolSpec {
        return .{ .name = "raise_stop", .description = "raises stop", .parameters_json_schema = "{\"type\":\"object\",\"properties\":{}}" };
    }
    fn execute(ctx: *anyopaque, alloc: Allocator, _: []const u8) !ToolResult {
        const self: *RaiseProbeTool = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        self.probe.raise();
        return ToolResult{ .ok = true, .output = try alloc.dupe(u8, "raised") };
    }
};

test "no tool dispatch after the stop signal (B12)" {
    const alloc = std.testing.allocator;
    var fake = S13FakeFs.init(alloc, "/wd");
    defer fake.deinit();

    var probe = stopmod.AtomicProbe{};
    var raise_impl = RaiseProbeTool{ .probe = &probe };
    const raise_t = raise_impl.toTool();
    var wt_impl = @import("../tool/write.zig").WriteTool.init(fake.toFs());
    const wt = wt_impl.toTool();
    const tools = [_]Tool{ raise_t, wt };

    // One turn with two tool calls: raise_stop first, then write_file which
    // must never execute because the signal fired after the first dispatch.
    const tcs = [_]provider.ToolCall{
        .{ .id = "c1", .name = "raise_stop", .arguments_json = "{}" },
        .{ .id = "c2", .name = "write_file", .arguments_json = "{\"path\":\"sentinel.txt\",\"data\":\"x\"}" },
    };
    const responses = [_]provider.ChatResponse{
        .{ .message = .{ .role = .assistant, .content = "", .tool_calls = &tcs }, .finish_reason = .tool_calls },
        .{ .message = .{ .role = .assistant, .content = "never reached" } },
    };
    var fp = fake13.FakeProvider.init(&responses);

    var repo_impl = S13Repo.FsGoalRepository.init(fake.toFs(), ".ziki", "sess1");
    const repo = repo_impl.toRepository();
    var ex = GoalExecutor{
        .alloc = alloc,
        .provider = fp.toProvider(),
        .tools = &tools,
        .repo = repo,
        .fs = fake.toFs(),
        .dir = ".ziki",
        .session_id = "sess1",
        .stop = probe.probe(),
    };
    var goal = try Goal.init(alloc, "do it", null, "sess1");
    defer goal.deinit(alloc);
    try ex.run(&goal);
    defer if (ex.report) |r| alloc.free(r);

    try std.testing.expect(goal.status == .aborted);
    try std.testing.expectEqualStrings("aborted by user", goal.progress);
    try std.testing.expect(!fake.toFs().exists("sentinel.txt")); // second dispatch never ran
    try std.testing.expectEqual(@as(usize, 1), fp.idx); // only the first response was consumed
}

test "provider response arriving after the signal is discarded (B13)" {
    const alloc = std.testing.allocator;
    var fake = S13FakeFs.init(alloc, "/wd");
    defer fake.deinit();

    var probe = stopmod.AtomicProbe{};
    var wt_impl = @import("../tool/write.zig").WriteTool.init(fake.toFs());
    const wt = wt_impl.toTool();
    const tools = [_]Tool{wt};

    // The provider raises the stop signal while the completion is in flight,
    // then returns a response with a tool call: the response must be
    // discarded (abort wins) and the tool must never execute.
    const SlowRaisingProvider = struct {
        probe: *stopmod.AtomicProbe,
        calls: usize = 0,

        fn toProvider(self: *@This()) provider.Provider {
            return .{ .ctx = self, .vtable = &vtable };
        }
        const vtable = provider.Provider.VTable{ .complete = complete, .name = name };
        fn name(_: *anyopaque) []const u8 {
            return "slow_raising";
        }
        fn complete(ctx: *anyopaque, pa: Allocator, _: provider.CompletionRequest) anyerror!provider.ChatResponse {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.calls += 1;
            self.probe.raise();
            std.Thread.sleep(150 * std.time.ns_per_ms);
            const tcs = [_]provider.ToolCall{.{ .id = "c9", .name = "write_file", .arguments_json = "{\"path\":\"late.txt\",\"data\":\"x\"}" }};
            return provider.ChatResponse{
                .message = .{ .role = .assistant, .content = "", .tool_calls = try pa.dupe(provider.ToolCall, &tcs) },
                .finish_reason = .tool_calls,
            };
        }
    };
    var srp = SlowRaisingProvider{ .probe = &probe };

    var repo_impl = S13Repo.FsGoalRepository.init(fake.toFs(), ".ziki", "sess1");
    const repo = repo_impl.toRepository();
    var ex = GoalExecutor{
        .alloc = alloc,
        .provider = srp.toProvider(),
        .tools = &tools,
        .repo = repo,
        .fs = fake.toFs(),
        .dir = ".ziki",
        .session_id = "sess1",
        .stop = probe.probe(),
    };
    var goal = try Goal.init(alloc, "do it", null, "sess1");
    defer goal.deinit(alloc);
    try ex.run(&goal);
    defer if (ex.report) |r| alloc.free(r);

    try std.testing.expect(goal.status == .aborted);
    try std.testing.expect(!fake.toFs().exists("late.txt")); // discarded: no work after the signal
    try std.testing.expectEqual(@as(usize, 1), srp.calls);
}

test "retry loop stops immediately when the signal is raised (B16)" {
    const alloc = std.testing.allocator;
    var fake = S13FakeFs.init(alloc, "/wd");
    defer fake.deinit();

    var probe = stopmod.AtomicProbe{};
    // Provider that raises the stop signal and then fails: the retry loop must
    // not attempt again after the signal.
    const RaiseFailProvider = struct {
        probe: *stopmod.AtomicProbe,
        calls: usize = 0,
        fn toProvider(self: *@This()) provider.Provider {
            return .{ .ctx = self, .vtable = &vtable };
        }
        const vtable = provider.Provider.VTable{ .complete = complete, .name = name };
        fn name(_: *anyopaque) []const u8 {
            return "raise_fail";
        }
        fn complete(ctx: *anyopaque, _: Allocator, _: provider.CompletionRequest) anyerror!provider.ChatResponse {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.calls += 1;
            self.probe.raise();
            return error.ProviderError;
        }
    };
    var rfp = RaiseFailProvider{ .probe = &probe };
    const tools = [_]Tool{};
    var repo_impl = S13Repo.FsGoalRepository.init(fake.toFs(), ".ziki", "sess1");
    const repo = repo_impl.toRepository();
    var ex = GoalExecutor{
        .alloc = alloc,
        .provider = rfp.toProvider(),
        .tools = &tools,
        .repo = repo,
        .fs = fake.toFs(),
        .dir = ".ziki",
        .session_id = "sess1",
        .stop = probe.probe(),
    };
    var goal = try Goal.init(alloc, "do it", null, "sess1");
    defer goal.deinit(alloc);
    try ex.run(&goal);
    defer if (ex.report) |r| alloc.free(r);

    try std.testing.expect(goal.status == .aborted);
    try std.testing.expectEqual(@as(usize, 1), rfp.calls); // no retry after the signal
}

test "executor persists the transcript after each turn (B5)" {
    const alloc = std.testing.allocator;
    var fake = S13FakeFs.init(alloc, "/wd");
    defer fake.deinit();

    const tcs = [_]provider.ToolCall{.{ .id = "c1", .name = "write_file", .arguments_json = "{\"path\":\"hello.txt\",\"data\":\"hi\"}" }};
    const responses = [_]provider.ChatResponse{
        .{ .message = .{ .role = .assistant, .content = "", .tool_calls = &tcs }, .finish_reason = .tool_calls },
        .{ .message = .{ .role = .assistant, .content = "done" } },
    };
    var fp = fake13.FakeProvider.init(&responses);
    var wt_impl = @import("../tool/write.zig").WriteTool.init(fake.toFs());
    const wt = wt_impl.toTool();
    const tools = [_]Tool{wt};
    var repo_impl = S13Repo.FsGoalRepository.init(fake.toFs(), ".ziki", "sess1");
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
    var goal = try Goal.init(alloc, "create hello.txt", null, "sess1");
    defer goal.deinit(alloc);
    try ex.run(&goal);
    defer if (ex.report) |r| alloc.free(r);
    try std.testing.expect(goal.status == .completed);

    // Terminal run clears the history (fresh-session invariant) — save a fresh
    // transcript manually here to prove loadHistory round-trips what a run saved.
    const seeded = [_]provider.ChatMessage{
        .{ .role = .system, .content = "sys" },
        .{ .role = .user, .content = "Goal: create hello.txt" },
    };
    try repo.saveHistory(alloc, goal.id, &seeded);
    const loaded = (try repo.loadHistory(alloc, goal.id)).?;
    defer S13Repo.freeHistory(alloc, loaded);
    try std.testing.expectEqual(@as(usize, 2), loaded.len);
    try std.testing.expectEqualStrings("Goal: create hello.txt", loaded[1].content);
}

test "seeded history is sent verbatim on resume (B6)" {
    const alloc = std.testing.allocator;
    var fake = S13FakeFs.init(alloc, "/wd");
    defer fake.deinit();

    const ok = provider.ChatResponse{ .message = .{ .role = .assistant, .content = "resumed and done" } };
    var rp = fake13.RecordingProvider.init(alloc, ok);
    defer rp.deinit();
    const tools = [_]Tool{};
    var repo_impl = S13Repo.FsGoalRepository.init(fake.toFs(), ".ziki", "sess1");
    const repo = repo_impl.toRepository();

    var ex = GoalExecutor{
        .alloc = alloc,
        .provider = rp.toProvider(),
        .tools = &tools,
        .repo = repo,
        .fs = fake.toFs(),
        .dir = ".ziki",
        .session_id = "sess1",
    };
    var goal = try Goal.init(alloc, "create hello.txt", null, "sess1");
    defer goal.deinit(alloc);
    goal.used.turns = 3; // carried from the earlier run
    goal.used.tokens = 250;

    const history = [_]provider.ChatMessage{
        .{ .role = .system, .content = "You are an autonomous coding agent." },
        .{ .role = .user, .content = "Goal: create hello.txt" },
        .{ .role = .assistant, .content = "", .tool_calls = &[_]provider.ToolCall{.{ .id = "c1", .name = "write_file", .arguments_json = "{\"path\":\"hello.txt\",\"data\":\"hi\"}" }} },
        .{ .role = .tool, .content = "exit=0\nhi", .tool_call_id = "c1" },
    };
    try ex.runWithHistory(&goal, &history);
    defer if (ex.report) |r| alloc.free(r);

    try std.testing.expect(goal.status == .completed);
    // The request replayed the persisted turns verbatim (SC-001).
    try std.testing.expect(std.mem.indexOf(u8, rp.log.items, "user:Goal: create hello.txt\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, rp.log.items, "tool:exit=0\nhi\n") != null);
    // Usage counters carried over rather than resetting.
    try std.testing.expect(goal.used.turns == 4);
    try std.testing.expect(goal.used.tokens > 250);
}

test "resume round-trip through the store continues an interrupted goal (B18)" {
    const alloc = std.testing.allocator;
    var fake = S13FakeFs.init(alloc, "/wd");
    defer fake.deinit();
    const wt_impl = @import("../tool/write.zig").WriteTool.init(fake.toFs());
    var wt_impl_mut = wt_impl;
    const wt = wt_impl_mut.toTool();
    const tools = [_]Tool{wt};

    // --- Run 1: interrupted after one turn (provider dies on the next turn).
    {
        const tcs = [_]provider.ToolCall{.{ .id = "c1", .name = "write_file", .arguments_json = "{\"path\":\"hello.txt\",\"data\":\"hi\"}" }};
        const responses = [_]provider.ChatResponse{
            .{ .message = .{ .role = .assistant, .content = "", .tool_calls = &tcs }, .finish_reason = .tool_calls, .usage = .{ .prompt_tokens = 60, .completion_tokens = 5 } },
        };
        var fp = fake13.FakeProvider.init(&responses);
        // Wrap: first call ok, later calls fail (simulating a crash mid-run).
        const OneShotThenFail = struct {
            fp: *fake13.FakeProvider,
            calls: usize = 0,
            fn toProvider(self: *@This()) provider.Provider {
                return .{ .ctx = self, .vtable = &vtable };
            }
            const vtable = provider.Provider.VTable{ .complete = complete, .name = name };
            fn name(_: *anyopaque) []const u8 {
                return "one_shot_then_fail";
            }
            fn complete(ctx: *anyopaque, pa: Allocator, req: provider.CompletionRequest) anyerror!provider.ChatResponse {
                const self: *@This() = @ptrCast(@alignCast(ctx));
                self.calls += 1;
                if (self.calls > 1) return error.ProviderError;
                return self.fp.toProvider().complete(pa, req);
            }
        };
        var otf = OneShotThenFail{ .fp = &fp };
        var repo_impl = S13Repo.FsGoalRepository.init(fake.toFs(), ".ziki", "sess1");
        const repo = repo_impl.toRepository();
        var ex = GoalExecutor{
            .alloc = alloc,
            .provider = otf.toProvider(),
            .tools = &tools,
            .repo = repo,
            .fs = fake.toFs(),
            .dir = ".ziki",
            .session_id = "sess1",
        };
        var goal = try Goal.init(alloc, "create hello.txt containing hi", null, "sess1");
        defer goal.deinit(alloc);
        goal.budgets.max_turns = 5;
        try std.testing.expectError(error.ProviderError, ex.run(&goal));
        _ = ex.report.?.len; // report exists; goal state must be persisted
        if (ex.report) |r| alloc.free(r);

        // Goal + transcript are in the store; status still active. The store
        // holds the last persisted state (end of turn 1; the failed turn's
        // in-memory increment was never saved).
        var reloaded = (try repo.load(alloc)).?;
        defer reloaded.deinit(alloc);
        try std.testing.expect(reloaded.status == .active);
        try std.testing.expectEqual(@as(u32, 1), reloaded.used.turns);
        const stored = try repo.loadHistory(alloc, reloaded.id);
        try std.testing.expect(stored != null);
        try std.testing.expect(stored.?.len >= 4); // system, goal, assistant tool_call, tool result

        // --- Run 2: resume with a fresh executor seeded from the store.
        const ok = provider.ChatResponse{ .message = .{ .role = .assistant, .content = "done" } };
        var rp = fake13.RecordingProvider.init(alloc, ok);
        defer rp.deinit();
        var repo2_impl = S13Repo.FsGoalRepository.init(fake.toFs(), ".ziki", "sess1");
        const repo2 = repo2_impl.toRepository();
        var ex2 = GoalExecutor{
            .alloc = alloc,
            .provider = rp.toProvider(),
            .tools = &tools,
            .repo = repo2,
            .fs = fake.toFs(),
            .dir = ".ziki",
            .session_id = "sess1",
        };
        try ex2.runWithHistory(&reloaded, stored.?);
        defer if (ex2.report) |r| alloc.free(r);
        defer S13Repo.freeHistory(alloc, stored.?);

        try std.testing.expect(reloaded.status == .completed);
        // The resume request replayed the persisted turns (SC-001).
        try std.testing.expect(std.mem.indexOf(u8, rp.log.items, "tool:wrote hello.txt\n") != null);
        // Transcript cleared at terminal so the next goal starts clean.
        try std.testing.expect((try repo2.loadHistory(alloc, reloaded.id)) == null);
    }
}

// ---------------------------------------------------------------------------
// Tests: already-applied detection + job report completeness (spec 016).
// ---------------------------------------------------------------------------

/// Minimal counting provider: scripted responses in order (repeats the last),
/// recording how many times the model was called at all.
const CountingProvider = struct {
    responses: []const provider.ChatResponse,
    idx: usize = 0,
    calls: usize = 0,

    fn init(responses: []const provider.ChatResponse) CountingProvider {
        return .{ .responses = responses };
    }
    fn toProvider(self: *CountingProvider) provider.Provider {
        return .{ .ctx = self, .vtable = &vtable };
    }
    const vtable = provider.Provider.VTable{ .complete = complete, .name = name };

    fn name(_: *anyopaque) []const u8 {
        return "counting";
    }
    fn complete(ctx: *anyopaque, alloc: Allocator, _: provider.CompletionRequest) !provider.ChatResponse {
        const self: *CountingProvider = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        const r = self.responses[@min(self.idx, self.responses.len - 1)];
        if (self.idx + 1 < self.responses.len) self.idx += 1;
        var tcs: ?[]provider.ToolCall = null;
        if (r.message.tool_calls) |src| {
            const owned = try alloc.alloc(provider.ToolCall, src.len);
            for (src, 0..) |tc, i| {
                owned[i] = .{
                    .id = try alloc.dupe(u8, tc.id),
                    .name = try alloc.dupe(u8, tc.name),
                    .arguments_json = try alloc.dupe(u8, tc.arguments_json),
                };
            }
            tcs = owned;
        }
        return .{ .message = .{ .role = r.message.role, .content = try alloc.dupe(u8, r.message.content), .tool_calls = tcs }, .finish_reason = r.finish_reason };
    }
};

test "already-satisfied criterion short-circuits before provider turns (A2)" {
    const alloc = std.testing.allocator;
    const FsGoalRepository = @import("../goal/repository.zig").FsGoalRepository;
    var fake = @import("../fs/fs.zig").FakeFs.init(alloc, "/wd");
    defer fake.deinit();

    // The pre-check IS the only model call: it answers exactly YES (strict —
    // a chatty reply that merely contains "YES" would not short-circuit).
    const responses = [_]provider.ChatResponse{
        .{ .message = .{ .role = .assistant, .content = "YES" } },
    };
    var cp = CountingProvider.init(&responses);
    const fp = cp.toProvider();

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
    var goal = try @import("../goal/goal.zig").Goal.init(alloc, "make it so", "criterion already holds", "sess1");
    defer goal.deinit(alloc);
    try ex.run(&goal);
    defer if (ex.report) |r| alloc.free(r);

    try std.testing.expect(goal.status == .completed);
    try std.testing.expect(std.mem.indexOf(u8, goal.progress, "already done") != null);
    try std.testing.expectEqual(@as(usize, 1), cp.calls); // the pre-check only — no work turns burned
    // The pre-check call is budget-accounted (review: it was silently free).
    try std.testing.expectEqual(@as(u32, 1), goal.used.turns);
    try std.testing.expect(goal.used.tokens > 0);
    try std.testing.expect(std.mem.indexOf(u8, ex.report.?, "already satisfied") != null);
}

test "unmet criterion still runs the normal loop after the pre-check (A2)" {
    const alloc = std.testing.allocator;
    const FsGoalRepository = @import("../goal/repository.zig").FsGoalRepository;
    var fake = @import("../fs/fs.zig").FakeFs.init(alloc, "/wd");
    defer fake.deinit();

    const tcs = [_]provider.ToolCall{.{ .id = "c1", .name = "write_file", .arguments_json = "{\"path\":\"hello.txt\",\"data\":\"hi\"}" }};
    // Response[0] feeds the spec 016 pre-check (says NO), then the loop runs.
    const responses = [_]provider.ChatResponse{
        .{ .message = .{ .role = .assistant, .content = "NO not yet" } },
        .{ .message = .{ .role = .assistant, .content = "", .tool_calls = &tcs }, .finish_reason = .tool_calls },
        .{ .message = .{ .role = .assistant, .content = "done" } },
        .{ .message = .{ .role = .assistant, .content = "YES now" } },
    };
    var cp = CountingProvider.init(&responses);
    const fp = cp.toProvider();

    const WriteTool = @import("../tool/write.zig").WriteTool;
    var wt_impl = WriteTool.init(fake.toFs());
    const write_t = wt_impl.toTool();
    const tools = [_]Tool{write_t};
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
    var goal = try @import("../goal/goal.zig").Goal.init(alloc, "write hello", "hello.txt exists with hi", "sess1");
    defer goal.deinit(alloc);
    try ex.run(&goal);
    defer if (ex.report) |r| alloc.free(r);

    // Pre-check said NO, then the loop ran to completion.
    try std.testing.expect(goal.status == .completed);
    try std.testing.expect(std.mem.indexOf(u8, goal.progress, "already done") == null);
    const content = try fake.readFile(alloc, "hello.txt");
    defer alloc.free(content);
    try std.testing.expectEqualStrings("hi", content);
}

test "pre-check accepts only a bare YES — a chatty reply runs the loop (A2)" {
    const alloc = std.testing.allocator;
    const FsGoalRepository = @import("../goal/repository.zig").FsGoalRepository;
    var fake = @import("../fs/fs.zig").FakeFs.init(alloc, "/wd");
    defer fake.deinit();

    const tcs = [_]provider.ToolCall{.{ .id = "c1", .name = "write_file", .arguments_json = "{\"path\":\"hello.txt\",\"data\":\"hi\"}" }};
    // The pre-check reply CONTAINS "YES" but is not a bare yes: with zero
    // workspace observations it is a guess, so the goal must NOT complete as
    // already done — the normal loop runs and does the work.
    const responses = [_]provider.ChatResponse{
        .{ .message = .{ .role = .assistant, .content = "NO — YES would require running the suite first" } },
        .{ .message = .{ .role = .assistant, .content = "", .tool_calls = &tcs }, .finish_reason = .tool_calls },
        .{ .message = .{ .role = .assistant, .content = "done" } },
        .{ .message = .{ .role = .assistant, .content = "YES now" } },
    };
    var cp = CountingProvider.init(&responses);
    const fp = cp.toProvider();

    const WriteTool = @import("../tool/write.zig").WriteTool;
    var wt_impl = WriteTool.init(fake.toFs());
    const write_t = wt_impl.toTool();
    const tools = [_]Tool{write_t};
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
    var goal = try @import("../goal/goal.zig").Goal.init(alloc, "write hello", "hello.txt exists with hi", "sess1");
    defer goal.deinit(alloc);
    try ex.run(&goal);
    defer if (ex.report) |r| alloc.free(r);

    try std.testing.expect(goal.status == .completed);
    try std.testing.expect(std.mem.indexOf(u8, goal.progress, "already done") == null);
    const content = try fake.readFile(alloc, "hello.txt");
    defer alloc.free(content);
    try std.testing.expectEqualStrings("hi", content);
}

test "job report covers intentional, untracked, and reverted paths (A3)" {
    const alloc = std.testing.allocator;
    const FsGoalRepository = @import("../goal/repository.zig").FsGoalRepository;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const cwd = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(cwd);

    // Real repo so the drift revert (git clean) operates for real.
    const run = struct {
        fn git(a: Allocator, dir: []const u8, args: []const []const u8) void {
            var argv = std.ArrayList([]const u8).initCapacity(a, 4) catch return;
            defer argv.deinit(a);
            argv.appendSlice(a, &.{ "git", "-C", dir }) catch return;
            argv.appendSlice(a, args) catch return;
            var child = std.process.Child.init(argv.items, a);
            child.stdin_behavior = .Ignore;
            child.stdout_behavior = .Ignore;
            child.stderr_behavior = .Ignore;
            _ = child.spawnAndWait() catch {};
        }
    };
    run.git(alloc, cwd, &.{ "init", "-q" });
    run.git(alloc, cwd, &.{ "config", "user.email", "t@t" });
    run.git(alloc, cwd, &.{ "config", "user.name", "t" });
    try tmp.dir.writeFile(.{ .sub_path = "tracked.txt", .data = "base" });
    run.git(alloc, cwd, &.{ "add", "tracked.txt" });
    run.git(alloc, cwd, &.{ "commit", "-q", "-m", "init" });
    // Pre-existing untracked user file: must survive untouched, unreported.
    try tmp.dir.writeFile(.{ .sub_path = "user-notes.txt", .data = "mine" });

    var impl = @import("../fs/fs.zig").RealFs.init(cwd);
    const fs = impl.toFs();
    const WriteTool = @import("../tool/write.zig").WriteTool;
    const BashTool = @import("../tool/bash.zig").BashTool;
    var wt_impl = WriteTool.init(fs);
    const write_t = wt_impl.toTool();
    var bt_impl = BashTool.init(fs, false, 30);
    const bash_t = bt_impl.toTool();
    const tools = [_]Tool{ write_t, bash_t };

    const tcs1 = [_]provider.ToolCall{.{ .id = "c1", .name = "write_file", .arguments_json = "{\"path\":\"intentional-new.txt\",\"data\":\"on purpose\"}" }};
    // BashTool spawns in the process cwd, so aim the drift at the tmp repo
    // with an absolute path.
    const drift_cmd = try std.fmt.allocPrint(alloc, "{{\"command\":\"echo drift > {s}/drift-file.txt\"}}", .{cwd});
    defer alloc.free(drift_cmd);
    const tcs2 = [_]provider.ToolCall{.{ .id = "c2", .name = "run_command", .arguments_json = drift_cmd }};
    // No criterion → no pre-check; the loop drives both tool calls directly.
    const responses = [_]provider.ChatResponse{
        .{ .message = .{ .role = .assistant, .content = "", .tool_calls = &tcs1 }, .finish_reason = .tool_calls },
        .{ .message = .{ .role = .assistant, .content = "", .tool_calls = &tcs2 }, .finish_reason = .tool_calls },
        .{ .message = .{ .role = .assistant, .content = "done" } },
    };
    var cp = CountingProvider.init(&responses);
    const fp = cp.toProvider();

    var repo_impl = FsGoalRepository.init(fs, ".ziki", "sess1");
    const repo = repo_impl.toRepository();
    var ex = GoalExecutor{
        .alloc = alloc,
        .provider = fp,
        .tools = &tools,
        .repo = repo,
        .fs = fs,
        .dir = ".ziki",
        .session_id = "sess1",
    };
    var goal = try @import("../goal/goal.zig").Goal.init(alloc, "produce the artifact", null, "sess1");
    defer goal.deinit(alloc);
    try ex.run(&goal);
    defer if (ex.report) |r| alloc.free(r);

    try std.testing.expect(goal.status == .completed);
    const r = ex.report.?;
    // Intentional (untracked) change reported as changed:
    try std.testing.expect(std.mem.indexOf(u8, r, "changed:\n  intentional-new.txt\n") != null);
    // Incidental drift reported as reverted (order-independent: the store dir
    // may be listed alongside it).
    try std.testing.expect(std.mem.indexOf(u8, r, "reverted (incidental):") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "  drift-file.txt") != null);
    // Nothing skipped:
    try std.testing.expect(std.mem.indexOf(u8, r, "skipped:\n  (none)") != null);
    // The user's pre-existing untracked file survived untouched and unreported:
    try std.testing.expect(fs.exists("user-notes.txt"));
    try std.testing.expect(std.mem.indexOf(u8, r, "user-notes") == null);
    try std.testing.expect(fs.exists("intentional-new.txt"));
    try std.testing.expect(!fs.exists("drift-file.txt"));
}
