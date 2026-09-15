const std = @import("std");
const Fs = @import("../fs/fs.zig").Fs;

/// Injectable "should the goal loop stop?" observation (spec 013 D5).
///
/// The executor turn loop, the Bash tool poll loop and the provider I/O wait
/// loop all poll this seam instead of reaching into the filesystem directly,
/// so abort behavior is testable with in-memory probes (DIP).
pub const StopProbe = struct {
    ctx: *anyopaque,
    check: *const fn (ctx: *anyopaque) bool,

    pub fn isStop(self: StopProbe) bool {
        return self.check(self.ctx);
    }
};

/// Probe backed by the `/stop` signal file — the production wiring used by
/// `/stop` (main.zig) and shared with the Bash tool so both observe the same
/// signal at the same instant.
pub const FsProbe = struct {
    fs: Fs,
    path: []const u8,

    pub fn init(fs: Fs, path: []const u8) FsProbe {
        return .{ .fs = fs, .path = path };
    }
    pub fn probe(self: *FsProbe) StopProbe {
        return .{ .ctx = self, .check = check };
    }
    fn check(ctx: *anyopaque) bool {
        const self: *FsProbe = @ptrCast(@alignCast(ctx));
        return self.fs.exists(self.path);
    }
};

/// Atomic-boolean probe for tests: raise it from provider/tool fakes to
/// script a mid-turn stop signal deterministically.
pub const AtomicProbe = struct {
    flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn probe(self: *AtomicProbe) StopProbe {
        return .{ .ctx = self, .check = check };
    }
    pub fn raise(self: *AtomicProbe) void {
        self.flag.store(true, .release);
    }
    fn check(ctx: *anyopaque) bool {
        const self: *AtomicProbe = @ptrCast(@alignCast(ctx));
        return self.flag.load(.acquire);
    }
};

/// Wall-clock probe for tests: stays silent until `delay_ms` elapsed since
/// `start_ms`, then fires. Shared by the executor and the Bash tool to script
/// a stop that appears *during* a long-running command.
pub const DelayedProbe = struct {
    delay_ms: i64,
    start_ms: i64 = std.time.milliTimestamp(),

    pub fn probe(self: *DelayedProbe) StopProbe {
        return .{ .ctx = self, .check = check };
    }
    pub fn reset(self: *DelayedProbe) void {
        self.start_ms = std.time.milliTimestamp();
    }
    fn check(ctx: *anyopaque) bool {
        const self: *DelayedProbe = @ptrCast(@alignCast(ctx));
        return std.time.milliTimestamp() - self.start_ms >= self.delay_ms;
    }
};

test "AtomicProbe raises and clears" {
    var p = AtomicProbe{};
    try std.testing.expect(!p.probe().isStop());
    p.raise();
    try std.testing.expect(p.probe().isStop());
}

test "FsProbe observes the stop file" {
    var fake = @import("../fs/fs.zig").FakeFs.init(std.testing.allocator, "/wd");
    defer fake.deinit();
    var p = FsProbe.init(fake.toFs(), ".ziki/stop.default");
    try std.testing.expect(!p.probe().isStop());
    try fake.toFs().writeFile(std.testing.allocator, ".ziki/stop.default", "");
    try std.testing.expect(p.probe().isStop());
}
