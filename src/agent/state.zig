const std = @import("std");
const Allocator = std.mem.Allocator;

/// Ziki's publishable agent state (FR-001). Single per process/session.
pub const AgentState = enum {
    idle,
    working,
    blocked,
    /// Reserved emission path for when Ziki cannot resolve its own state (FR-005).
    unknown,

    pub fn jsonString(self: AgentState) []const u8 {
        return switch (self) {
            .idle => "idle",
            .working => "working",
            .blocked => "blocked",
            .unknown => "unknown",
        };
    }

    /// Map onto Herdr's `AgentState` enum (FR-005): idle→Idle, working→Working,
    /// blocked→Blocked, unknown→Unknown.
    pub fn toHerdr(self: AgentState) []const u8 {
        return switch (self) {
            .idle => "Idle",
            .working => "Working",
            .blocked => "Blocked",
            .unknown => "Unknown",
        };
    }
};

/// The structured push payload sent to Herdr's `pane report agent` API
/// (contract §2). Field names match the JSON contract exactly.
pub const PaneReportParams = struct {
    pane_id: []const u8,
    source: []const u8,
    agent: []const u8,
    state: []const u8,
    message: ?[]const u8,
    seq: u64,
    agent_session_id: []const u8,
    agent_session_path: []const u8,
};

/// DI boundary for pushing state to Herdr (mirrors Provider/Transport vtables).
pub const HerdrReporter = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        report: *const fn (ctx: *anyopaque, alloc: Allocator, params: PaneReportParams) anyerror!void,
    };

    pub fn report(self: HerdrReporter, alloc: Allocator, params: PaneReportParams) !void {
        return self.vtable.report(self.ctx, alloc, params);
    }
};

/// Owns the state-publication side-effects (FR-002/003/004/007/008).
pub const StatePublisher = struct {
    alloc: Allocator,
    reporter: ?HerdrReporter,
    writer: std.io.AnyWriter,
    pane_id: []const u8,
    source: []const u8,
    agent: []const u8,
    session_id: []const u8,
    session_path: []const u8,
    seq: u64,

    pub fn init(
        alloc: Allocator,
        reporter: ?HerdrReporter,
        writer: std.io.AnyWriter,
        pane_id: []const u8,
        session_id: []const u8,
        session_path: []const u8,
    ) StatePublisher {
        return .{
            .alloc = alloc,
            .reporter = reporter,
            .writer = writer,
            .pane_id = pane_id,
            .source = "herdr:ziki",
            .agent = "ziki",
            .session_id = session_id,
            .session_path = session_path,
            .seq = 0,
        };
    }

    /// Publish a transition: bump seq, push via reporter (best-effort, errors
    /// swallowed so publication never crashes a turn), and emit the screen marker
    /// + OSC title to the injected writer (FR-002/003/004/007/008).
    pub fn publish(self: *StatePublisher, state: AgentState, message: ?[]const u8) void {
        self.seq += 1;
        const s = state.jsonString();
        if (self.reporter) |reporter| {
            const params = PaneReportParams{
                .pane_id = self.pane_id,
                .source = self.source,
                .agent = self.agent,
                .state = s,
                .message = message,
                .seq = self.seq,
                .agent_session_id = self.session_id,
                .agent_session_path = self.session_path,
            };
            // Best-effort: a push failure must never break the goal turn.
            reporter.report(self.alloc, params) catch {};
        }
        const msg_part = if (message) |m| std.fmt.allocPrint(self.alloc, " {s}", .{m}) catch return else "";
        defer if (message != null) self.alloc.free(msg_part);
        const marker = std.fmt.allocPrint(
            self.alloc,
            "[ziki-state: {s}]{s}\n",
            .{ s, msg_part },
        ) catch return;
        defer self.alloc.free(marker);
        self.writer.writeAll(marker) catch {};
        const osc = std.fmt.allocPrint(self.alloc, "\x1b]2;ziki:{s}\x07", .{s}) catch return;
        defer self.alloc.free(osc);
        self.writer.writeAll(osc) catch {};
    }
};

/// Scripted in-memory `HerdrReporter` for tests (records the last push, can be
/// made to fail to exercise error isolation). Mirrors `FakeProvider`.
pub const FakeHerdrReporter = struct {
    alloc: Allocator,
    last: ?PaneReportParams = null,
    fail_next: bool = false,

    pub fn init(alloc: Allocator) FakeHerdrReporter {
        return .{ .alloc = alloc };
    }
    pub fn toReporter(self: *FakeHerdrReporter) HerdrReporter {
        return .{ .ctx = self, .vtable = &vtable };
    }
    const vtable = HerdrReporter.VTable{ .report = report };

    fn report(ctx: *anyopaque, alloc: Allocator, params: PaneReportParams) !void {
        const self: *FakeHerdrReporter = @ptrCast(@alignCast(ctx));
        if (self.fail_next) return error.FakeReporterFailure;
        // Free the previously recorded report so repeated publishes don't leak.
        if (self.last) |old| freeParams(alloc, old);
        self.last = try cloneParams(alloc, params);
    }
    pub fn deinit(self: *FakeHerdrReporter) void {
        if (self.last) |p| freeParams(self.alloc, p);
    }
};

fn cloneParams(alloc: Allocator, p: PaneReportParams) !PaneReportParams {
    return PaneReportParams{
        .pane_id = try alloc.dupe(u8, p.pane_id),
        .source = try alloc.dupe(u8, p.source),
        .agent = try alloc.dupe(u8, p.agent),
        .state = try alloc.dupe(u8, p.state),
        .message = if (p.message) |m| try alloc.dupe(u8, m) else null,
        .seq = p.seq,
        .agent_session_id = try alloc.dupe(u8, p.agent_session_id),
        .agent_session_path = try alloc.dupe(u8, p.agent_session_path),
    };
}
fn freeParams(alloc: Allocator, p: PaneReportParams) void {
    alloc.free(p.pane_id);
    alloc.free(p.source);
    alloc.free(p.agent);
    alloc.free(p.state);
    if (p.message) |m| alloc.free(m);
    alloc.free(p.agent_session_id);
    alloc.free(p.agent_session_path);
}

// ---------------------------------------------------------------------------
// Tests (TDD red phase). The module above is a stub; these fail until the real
// implementation lands.
// ---------------------------------------------------------------------------

fn captureWriter(alloc: Allocator, buf: []u8) std.io.FixedBufferStream([]u8) {
    _ = alloc;
    return std.io.fixedBufferStream(buf);
}

test "AgentState.toHerdr maps to Herdr states (FR-005)" {
    try std.testing.expectEqualStrings("Idle", AgentState.idle.toHerdr());
    try std.testing.expectEqualStrings("Working", AgentState.working.toHerdr());
    try std.testing.expectEqualStrings("Blocked", AgentState.blocked.toHerdr());
}

test "AgentState.unknown maps to Unknown (FR-005 boundary)" {
    try std.testing.expectEqualStrings("Unknown", AgentState.unknown.toHerdr());
}

test "StatePublisher.publish pushes correct PaneReportParams (FR-002)" {
    var buf: [1024]u8 = undefined;
    var fbs = captureWriter(std.testing.allocator, &buf);
    const w = fbs.writer().any();
    var fake = FakeHerdrReporter.init(std.testing.allocator);
    defer fake.deinit();
    var sp = StatePublisher.init(std.testing.allocator, fake.toReporter(), w, "pane-1", "goal-1", "/wd/.ziki");
    sp.publish(.working, null);
    const p = fake.last orelse @panic("no report published");
    try std.testing.expectEqualStrings("pane-1", p.pane_id);
    try std.testing.expectEqualStrings("herdr:ziki", p.source);
    try std.testing.expectEqualStrings("ziki", p.agent);
    try std.testing.expectEqualStrings("working", p.state);
    try std.testing.expectEqual(p.seq, 1);
    try std.testing.expectEqualStrings("goal-1", p.agent_session_id);
    try std.testing.expectEqualStrings("/wd/.ziki", p.agent_session_path);
    try std.testing.expect(p.message == null);
}

test "StatePublisher seq is strictly increasing (SC-006)" {
    var buf: [1024]u8 = undefined;
    var fbs = captureWriter(std.testing.allocator, &buf);
    const w = fbs.writer().any();
    var fake = FakeHerdrReporter.init(std.testing.allocator);
    defer fake.deinit();
    var sp = StatePublisher.init(std.testing.allocator, fake.toReporter(), w, "pane-1", "g", "/wd");
    sp.publish(.working, null);
    const first = (fake.last orelse @panic("no report")).seq;
    sp.publish(.blocked, null);
    const second = (fake.last orelse @panic("no report")).seq;
    try std.testing.expectEqual(first, 1);
    try std.testing.expectEqual(second, 2);
    try std.testing.expect(second > first);
}

test "StatePublisher emits screen marker [ziki-state: <state>] (FR-003)" {
    var buf: [1024]u8 = undefined;
    var fbs = captureWriter(std.testing.allocator, &buf);
    const w = fbs.writer().any();
    var fake = FakeHerdrReporter.init(std.testing.allocator);
    defer fake.deinit();
    var sp = StatePublisher.init(std.testing.allocator, fake.toReporter(), w, "pane-1", "g", "/wd");
    sp.publish(.working, null);
    const written = buf[0..fbs.pos];
    try std.testing.expect(std.mem.indexOf(u8, written, "[ziki-state: working]") != null);
}

test "StatePublisher emits OSC title ziki:<state> (FR-004)" {
    var buf: [1024]u8 = undefined;
    var fbs = captureWriter(std.testing.allocator, &buf);
    const w = fbs.writer().any();
    var fake = FakeHerdrReporter.init(std.testing.allocator);
    defer fake.deinit();
    var sp = StatePublisher.init(std.testing.allocator, fake.toReporter(), w, "pane-1", "g", "/wd");
    sp.publish(.blocked, null);
    const written = buf[0..fbs.pos];
    try std.testing.expect(std.mem.indexOf(u8, written, "ziki:blocked") != null);
}

test "StatePublisher marker includes message when present, omits when absent (FR-003/FR-004)" {
    var buf: [1024]u8 = undefined;
    var fbs = captureWriter(std.testing.allocator, &buf);
    const w = fbs.writer().any();
    var fake = FakeHerdrReporter.init(std.testing.allocator);
    defer fake.deinit();
    var sp = StatePublisher.init(std.testing.allocator, fake.toReporter(), w, "pane-1", "g", "/wd");
    sp.publish(.working, null);
    const a = buf[0..fbs.pos];
    try std.testing.expect(std.mem.indexOf(u8, a, "[ziki-state: working]") != null);
    try std.testing.expect(std.mem.indexOf(u8, a, "[ziki-state: working] ") == null);
    sp.publish(.blocked, "criterion not satisfied");
    const b = buf[0..fbs.pos];
    try std.testing.expect(std.mem.indexOf(u8, b, "[ziki-state: blocked] criterion not satisfied") != null);
}

test "StatePublisher with null reporter still emits marker, no push, no crash (FR-008)" {
    var buf: [1024]u8 = undefined;
    var fbs = captureWriter(std.testing.allocator, &buf);
    const w = fbs.writer().any();
    var sp = StatePublisher.init(std.testing.allocator, null, w, "pane-1", "g", "/wd");
    sp.publish(.working, null);
    const written = buf[0..fbs.pos];
    try std.testing.expect(std.mem.indexOf(u8, written, "[ziki-state: working]") != null);
}

test "StatePublisher swallows reporter error and still emits marker (FR-008)" {
    var buf: [1024]u8 = undefined;
    var fbs = captureWriter(std.testing.allocator, &buf);
    const w = fbs.writer().any();
    var fake = FakeHerdrReporter.init(std.testing.allocator);
    defer fake.deinit();
    fake.fail_next = true;
    var sp = StatePublisher.init(std.testing.allocator, fake.toReporter(), w, "pane-1", "g", "/wd");
    // Must not panic/crash:
    sp.publish(.working, null);
    const written = buf[0..fbs.pos];
    try std.testing.expect(std.mem.indexOf(u8, written, "[ziki-state: working]") != null);
}

test "StatePublisher push is authoritative and consistent with marker (FR-007)" {
    var buf: [1024]u8 = undefined;
    var fbs = captureWriter(std.testing.allocator, &buf);
    const w = fbs.writer().any();
    var fake = FakeHerdrReporter.init(std.testing.allocator);
    defer fake.deinit();
    var sp = StatePublisher.init(std.testing.allocator, fake.toReporter(), w, "pane-1", "g", "/wd");
    const states = [_]AgentState{ .idle, .working, .blocked };
    for (states) |s| {
        sp.publish(s, null);
        const written = buf[0..fbs.pos];
        const pushed = (fake.last orelse @panic("no report")).state;
        const needle = try std.fmt.allocPrint(std.testing.allocator, "[ziki-state: {s}]", .{pushed});
        defer std.testing.allocator.free(needle);
        try std.testing.expect(std.mem.indexOf(u8, written, needle) != null);
    }
}

test "FakeHerdrReporter records last params and can be forced to fail (U13)" {
    var buf: [1024]u8 = undefined;
    var fbs = captureWriter(std.testing.allocator, &buf);
    const w = fbs.writer().any();
    var fake = FakeHerdrReporter.init(std.testing.allocator);
    defer fake.deinit();
    var sp = StatePublisher.init(std.testing.allocator, fake.toReporter(), w, "pane-9", "sid-9", "/wd");
    sp.publish(.working, "hello");
    const p = fake.last orelse @panic("no report");
    try std.testing.expectEqualStrings("pane-9", p.pane_id);
    try std.testing.expectEqualStrings("working", p.state);
    try std.testing.expectEqualStrings("hello", p.message.?);
    // Forced failure: the report is NOT recorded and publication continues.
    fake.fail_next = true;
    if (fake.last) |old| {
        freeParams(fake.alloc, old);
        fake.last = null;
    }
    sp.publish(.idle, null);
    try std.testing.expectEqual(@as(?PaneReportParams, null), fake.last);
}
