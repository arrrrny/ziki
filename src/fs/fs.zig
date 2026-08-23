const std = @import("std");
const Allocator = std.mem.Allocator;

/// Expand a leading home-directory shorthand to the user's `$HOME`.
///
/// - `"~/foo"` / `"~/"`  -> `"$HOME/foo"`
/// - `"~"` (bare)       -> `"$HOME"`
/// - anything else      -> returned unchanged (caller-owned copy)
///
/// The Zig stdlib has no `expandTilde`; we read `HOME` via
/// `std.process.getEnvVarOwned`. When `HOME` is unset or the path does not
/// start with `~`, the original path is returned (FR-001).
pub fn expandTilde(alloc: Allocator, path: []const u8) ![]u8 {
    if (path.len == 0 or path[0] != '~') return alloc.dupe(u8, path);
    const home = std.process.getEnvVarOwned(alloc, "HOME") catch return alloc.dupe(u8, path);
    if (path.len == 1) {
        // bare "~" -> $HOME (fresh copy; `home` is freed, never returned).
        const dup = try alloc.dupe(u8, home);
        alloc.free(home);
        return dup;
    }
    if (path[1] == '/') {
        if (path.len == 2) {
            // "~/" alone means the home directory.
            const dup = try alloc.dupe(u8, home);
            alloc.free(home);
            return dup;
        }
        const joined = try std.fs.path.join(alloc, &.{ home, path[2..] });
        alloc.free(home);
        return joined;
    }
    // "~otheruser" is unsupported; leave unchanged (return a copy).
    const dup = try alloc.dupe(u8, path);
    alloc.free(home);
    return dup;
}

/// Filesystem boundary (DI). Tools and the goal repository depend on this
/// interface, never on std.fs directly, so they are testable with FakeFs.
pub const Fs = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        read_file: *const fn (ctx: *anyopaque, alloc: Allocator, path: []const u8) anyerror![]u8,
        write_file: *const fn (ctx: *anyopaque, alloc: Allocator, path: []const u8, data: []const u8) anyerror!void,
        exists: *const fn (ctx: *anyopaque, path: []const u8) bool,
        remove: *const fn (ctx: *anyopaque, path: []const u8) anyerror!void,
        cwd: *const fn (ctx: *anyopaque) []const u8,
    };

    pub fn readFile(self: Fs, alloc: Allocator, path: []const u8) ![]u8 {
        return self.vtable.read_file(self.ctx, alloc, path);
    }
    pub fn writeFile(self: Fs, alloc: Allocator, path: []const u8, data: []const u8) !void {
        return self.vtable.write_file(self.ctx, alloc, path, data);
    }
    pub fn exists(self: Fs, path: []const u8) bool {
        return self.vtable.exists(self.ctx, path);
    }
    pub fn remove(self: Fs, path: []const u8) !void {
        return self.vtable.remove(self.ctx, path);
    }
    pub fn cwd(self: Fs) []const u8 {
        return self.vtable.cwd(self.ctx);
    }
};

/// Real filesystem backed by std.fs, rooted at a working directory.
pub const RealFs = struct {
    cwd_path: []const u8,

    pub fn init(cwd_path: []const u8) RealFs {
        return .{ .cwd_path = cwd_path };
    }
    pub fn toFs(self: *RealFs) Fs {
        return .{ .ctx = self, .vtable = &vtable };
    }
    const vtable = Fs.VTable{
        .read_file = readFile,
        .write_file = writeFile,
        .exists = exists,
        .remove = remove,
        .cwd = cwd,
    };

    fn resolve(self: *RealFs, alloc: Allocator, path: []const u8) ![]u8 {
        // FR-001: expand a leading `~` to `$HOME` before resolving, so file
        // tools accept home-directory shorthand (read/edit/write/search).
        const expanded = try expandTilde(alloc, path);
        defer alloc.free(expanded);
        if (std.fs.path.isAbsolute(expanded)) return alloc.dupe(u8, expanded);
        return std.fs.path.join(alloc, &.{ self.cwd_path, expanded });
    }

    fn readFile(ctx: *anyopaque, alloc: Allocator, path: []const u8) ![]u8 {
        const self: *RealFs = @ptrCast(@alignCast(ctx));
        const abs = try self.resolve(alloc, path);
        defer alloc.free(abs);
        return std.fs.cwd().readFileAlloc(alloc, abs, std.math.maxInt(usize)) catch |e| {
            if (e == error.FileNotFound) return error.FileNotFound;
            return e;
        };
    }
    fn writeFile(ctx: *anyopaque, alloc: Allocator, path: []const u8, data: []const u8) !void {
        const self: *RealFs = @ptrCast(@alignCast(ctx));
        const abs = try self.resolve(alloc, path);
        defer alloc.free(abs);
        var dir = std.fs.cwd();
        if (std.fs.path.dirname(abs)) |d| try dir.makePath(d);
        try std.fs.cwd().writeFile(.{ .sub_path = abs, .data = data });
    }
    fn exists(ctx: *anyopaque, path: []const u8) bool {
        const self: *RealFs = @ptrCast(@alignCast(ctx));
        const abs = self.resolve(std.heap.page_allocator, path) catch return false;
        defer std.heap.page_allocator.free(abs);
        std.fs.cwd().access(abs, .{}) catch return false;
        return true;
    }
    fn remove(ctx: *anyopaque, path: []const u8) !void {
        const self: *RealFs = @ptrCast(@alignCast(ctx));
        const abs = try self.resolve(std.heap.page_allocator, path);
        defer std.heap.page_allocator.free(abs);
        std.fs.cwd().deleteFile(abs) catch |e| {
            if (e == error.FileNotFound) return error.FileNotFound;
            return e;
        };
    }
    fn cwd(ctx: *anyopaque) []const u8 {
        const self: *RealFs = @ptrCast(@alignCast(ctx));
        return self.cwd_path;
    }
};

/// In-memory filesystem for tests.
pub const FakeFs = struct {
    cwd_path: []const u8,
    files: std.StringHashMap([]const u8),
    alloc: Allocator,

    pub fn init(alloc: Allocator, cwd_path: []const u8) FakeFs {
        return .{ .cwd_path = cwd_path, .files = std.StringHashMap([]const u8).init(alloc), .alloc = alloc };
    }
    pub fn toFs(self: *FakeFs) Fs {
        return .{ .ctx = self, .vtable = &vtable };
    }
    const vtable = Fs.VTable{
        .read_file = readFileVt,
        .write_file = writeFileVt,
        .exists = exists,
        .remove = remove,
        .cwd = cwd,
    };

    pub fn readFile(self: *FakeFs, alloc: Allocator, path: []const u8) ![]u8 {
        const f = self.files.get(path) orelse return error.FileNotFound;
        return alloc.dupe(u8, f);
    }
    fn readFileVt(ctx: *anyopaque, alloc: Allocator, path: []const u8) ![]u8 {
        const self: *FakeFs = @ptrCast(@alignCast(ctx));
        return self.readFile(alloc, path);
    }

    /// Frees every stored key/value and the map. Storage is always owned by
    /// `self.alloc`, so only that allocator is used here (never the caller's).
    pub fn deinit(self: *FakeFs) void {
        var it = self.files.iterator();
        while (it.next()) |e| {
            self.alloc.free(e.key_ptr.*);
            self.alloc.free(e.value_ptr.*);
        }
        self.files.deinit();
    }

    /// Writes a file into the in-memory map. The key/value copies are owned by
    /// `self.alloc` (the same allocator backing `self.files`), so they survive
    /// the caller's arena and stay valid until `deinit`.
    pub fn writeFile(self: *FakeFs, _: Allocator, path: []const u8, data: []const u8) !void {
        const dup_data = try self.alloc.dupe(u8, data);
        if (self.files.getPtr(path)) |old| {
            self.alloc.free(old.*);
            old.* = dup_data;
            return;
        }
        const dup_path = try self.alloc.dupe(u8, path);
        try self.files.put(dup_path, dup_data);
    }
    fn writeFileVt(ctx: *anyopaque, alloc: Allocator, path: []const u8, data: []const u8) !void {
        const self: *FakeFs = @ptrCast(@alignCast(ctx));
        return self.writeFile(alloc, path, data);
    }
    fn exists(ctx: *anyopaque, path: []const u8) bool {
        const self: *FakeFs = @ptrCast(@alignCast(ctx));
        return self.files.contains(path);
    }
    fn remove(ctx: *anyopaque, path: []const u8) !void {
        const self: *FakeFs = @ptrCast(@alignCast(ctx));
        const kv = self.files.fetchRemove(path) orelse return error.FileNotFound;
        self.alloc.free(kv.key);
        self.alloc.free(kv.value);
    }
    fn cwd(ctx: *anyopaque) []const u8 {
        const self: *FakeFs = @ptrCast(@alignCast(ctx));
        return self.cwd_path;
    }
};

test "RealFs round-trip via temp" {
    const tmp = std.testing.tmpDir(.{});
    const dir = tmp.dir;
    const path = "rt.txt";
    try dir.writeFile(.{ .sub_path = path, .data = "hello" });
    const got = try dir.readFileAlloc(std.testing.allocator, path, 1024);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("hello", got);
}

test "FakeFs round-trip" {
    var fake = FakeFs.init(std.testing.allocator, "/wd");
    defer fake.deinit();
    const fs = fake.toFs();
    try fs.writeFile(std.testing.allocator, "a.txt", "data");
    try std.testing.expect(fs.exists("a.txt"));
    const got = try fs.readFile(std.testing.allocator, "a.txt");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("data", got);
    try fs.remove("a.txt");
    try std.testing.expect(!fs.exists("a.txt"));
}

test "expandTilde resolves ~ to $HOME" {
    const alloc = std.testing.allocator;
    // HOME is always set in this environment; derive the expected result from it
    // so the assertion is deterministic regardless of its concrete value.
    const home = std.process.getEnvVarOwned(alloc, "HOME") catch {
        // No HOME (e.g. some CI): expansion is a no-op; just confirm that.
        const same = try expandTilde(alloc, "~/foo");
        defer alloc.free(same);
        try std.testing.expectEqualStrings("~/foo", same);
        return;
    };
    defer alloc.free(home);

    // ~/foo -> $HOME/foo (a distinct allocation).
    const foo = try expandTilde(alloc, "~/foo");
    defer alloc.free(foo);
    const want_foo = try std.fs.path.join(alloc, &.{ home, "foo" });
    defer alloc.free(want_foo);
    try std.testing.expectEqualStrings(want_foo, foo);

    // "~/ and bare "~" alias $HOME (content equality; fresh allocation, freed below).
    const slash = try expandTilde(alloc, "~/");
    defer alloc.free(slash);
    try std.testing.expectEqualStrings(home, slash);

    const bare = try expandTilde(alloc, "~");
    defer alloc.free(bare);
    try std.testing.expectEqualStrings(home, bare);

    // Non-tilde paths are returned as a distinct copy (unchanged).
    const plain = try expandTilde(alloc, "src/main.zig");
    defer alloc.free(plain);
    try std.testing.expectEqualStrings("src/main.zig", plain);
}
