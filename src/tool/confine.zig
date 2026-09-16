//! Path confinement for file-touching tools (spec 015, issue #18 Lane C).
//!
//! `check` returns null when `path` is safely inside the workspace root
//! (`fs.cwd()`), or an owned refusal message when it escapes — by `..`
//! traversal, by being an absolute path outside the root, by using the `~`
//! home shorthand (workspace-relative policy wins for tools), or by resolving
//! through a symlink to a real location outside the root (fail closed).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Fs = @import("../fs/fs.zig").Fs;

/// Validate `raw_path` against the workspace root. Null = allowed; otherwise
/// the returned message (allocated with `alloc`) is the structured refusal.
pub fn check(alloc: Allocator, fs: Fs, raw_path: []const u8) ?[]const u8 {
    const root = fs.cwd();
    if (raw_path.len == 0) return refusalMsg(alloc, "empty path", .{});

    // Home shorthand resolves outside the workspace: refused for tools
    // (workspace-relative policy; `expandTilde` stays for non-tool Fs users).
    if (raw_path[0] == '~') return refusalMsg(alloc, "path escapes workspace root: {s}", .{raw_path});

    if (std.fs.path.isAbsolute(raw_path)) {
        // Collapse `..`/`.` lexically first so the verdict never depends on
        // filesystem state (FakeFs realpath is unnormalized).
        const norm = lexNormalize(alloc, raw_path) catch
            return refusalMsg(alloc, "path escapes workspace root: {s}", .{raw_path});
        defer alloc.free(norm);
        if (!underRoot(root, norm))
            return refusalMsg(alloc, "path escapes workspace root: {s}", .{raw_path});
    } else {
        if (escapesLexically(raw_path))
            return refusalMsg(alloc, "path escapes workspace root: {s}", .{raw_path});
    }

    // Symlink escape: when the path (or its parent, for not-yet-existing
    // files) really exists, its canonical location must still be inside.
    if (canonicalUnder(alloc, fs, root, raw_path)) |msg| return msg;
    if (std.fs.path.dirname(raw_path)) |parent| {
        if (canonicalUnder(alloc, fs, root, parent)) |msg| {
            defer alloc.free(msg);
            return std.fmt.allocPrint(alloc, "{s} (parent {s})", .{ msg, parent }) catch msg;
        }
    }
    return null;
}

fn refusalMsg(alloc: Allocator, comptime fmt: []const u8, args: anytype) ?[]const u8 {
    const prefix = "confined: ";
    const body = std.fmt.allocPrint(alloc, fmt, args) catch return null;
    defer alloc.free(body);
    const msg = std.mem.concat(alloc, u8, &.{ prefix, body }) catch return null;
    return msg;
}

/// True when `path` contains a `..` component that climbs above the top.
fn escapesLexically(relative: []const u8) bool {
    var depth: usize = 0;
    var it = std.mem.splitScalar(u8, relative, '/');
    while (it.next()) |comp| {
        if (comp.len == 0 or std.mem.eql(u8, comp, ".")) continue;
        if (std.mem.eql(u8, comp, "..")) {
            if (depth == 0) return true;
            depth -= 1;
        } else {
            depth += 1;
        }
    }
    return false;
}

/// Collapse `.` and `..` components lexically (absolute paths only).
fn lexNormalize(alloc: Allocator, abs: []const u8) ![]u8 {
    var out = try std.ArrayList(u8).initCapacity(alloc, 0);
    errdefer out.deinit(alloc);
    var it = std.mem.splitScalar(u8, abs, '/');
    while (it.next()) |comp| {
        if (comp.len == 0 or std.mem.eql(u8, comp, ".")) continue;
        if (std.mem.eql(u8, comp, "..")) {
            // Pop the last written component, never below the top.
            while (out.items.len > 0 and out.items[out.items.len - 1] != '/') _ = out.pop();
            if (out.items.len > 0) _ = out.pop();
        } else {
            try out.append(alloc, '/');
            try out.appendSlice(alloc, comp);
        }
    }
    if (out.items.len == 0) try out.append(alloc, '/');
    return out.toOwnedSlice(alloc);
}

test "lexNormalize collapses interior dot components" {
    const alloc = std.testing.allocator;
    const cases = .{
        .{ "/wd/../outside", "/outside" },
        .{ "/wd/./sub/../f.txt", "/wd/f.txt" },
        .{ "/a/b/../../c", "/c" },
        .{ "/..", "/" },
        .{ "/", "/" },
    };
    inline for (cases) |case| {
        const got = try lexNormalize(alloc, case[0]);
        defer alloc.free(got);
        try std.testing.expectEqualStrings(case[1], got);
    }
}

/// Component-wise prefix test so `/wd2/x` is not confused with `/wd/x`.
fn underRoot(root: []const u8, abs: []const u8) bool {
    var root_it = std.mem.splitScalar(u8, root, '/');
    var path_it = std.mem.splitScalar(u8, abs, '/');
    while (root_it.next()) |rc| {
        if (rc.len == 0) continue;
        var pc = path_it.next() orelse return false;
        while (pc.len == 0) pc = path_it.next() orelse return false;
        if (!std.mem.eql(u8, rc, pc)) return false;
    }
    return true;
}

/// Realpath the given path (when it exists) and verify it stays under root.
/// Returns a refusal message on escape, null when allowed or unverifiable.
fn canonicalUnder(alloc: Allocator, fs: Fs, root: []const u8, path: []const u8) ?[]const u8 {
    const real = fs.realpath(alloc, path) catch return null;
    defer alloc.free(real);
    if (!underRoot(root, real)) {
        if (std.mem.startsWith(u8, path, "~"))
            return refusalMsg(alloc, "path escapes workspace root: {s}", .{path});
        return refusalMsg(alloc, "path escapes workspace root: {s} -> {s}", .{ path, real });
    }
    return null;
}

// ---------------------------------------------------------------------------
// Tests (TDD red phase — fail against the permissive stub).
// ---------------------------------------------------------------------------

fn refusal(alloc: Allocator, fs: Fs, path: []const u8) !void {
    const msg = check(alloc, fs, path) orelse return error.ExpectedRefusal;
    defer alloc.free(msg);
    try std.testing.expect(std.mem.startsWith(u8, msg, "confined: "));
}

fn allowed(alloc: Allocator, fs: Fs, path: []const u8) !void {
    if (check(alloc, fs, path)) |msg| {
        defer alloc.free(msg);
        std.debug.print("unexpected refusal: {s}\n", .{msg});
        return error.UnexpectedRefusal;
    }
}

test "confine refuses .. traversal and absolute paths outside the root (A1)" {
    const alloc = std.testing.allocator;
    var fake = @import("../fs/fs.zig").FakeFs.init(alloc, "/wd");
    defer fake.deinit();
    const fs = fake.toFs();

    // `..` escapes, in several shapes.
    try refusal(alloc, fs, "../outside.txt");
    try refusal(alloc, fs, "sub/../../outside.txt");
    try refusal(alloc, fs, "..");
    try refusal(alloc, fs, "a/b/../../../x");
    // Absolute paths outside the root.
    try refusal(alloc, fs, "/etc/passwd");
    try refusal(alloc, fs, "/wd2/neighbor.txt");
    try refusal(alloc, fs, "/"); // the root itself via absolute form outside cwd
    // Home shorthand leaves the workspace.
    try refusal(alloc, fs, "~/.ssh/id_rsa");
    // Absolute paths with interior `..` collapse before the prefix test.
    try refusal(alloc, fs, "/wd/../outside");
}

test "confine allows ordinary in-root paths (U1)" {
    const alloc = std.testing.allocator;
    var fake = @import("../fs/fs.zig").FakeFs.init(alloc, "/wd");
    defer fake.deinit();
    const fs = fake.toFs();

    try allowed(alloc, fs, "f.txt");
    try allowed(alloc, fs, "sub/dir/file.zig");
    try allowed(alloc, fs, "./here.txt");
    try allowed(alloc, fs, "sub/../sibling.txt"); // stays inside after normalize
    // Absolute path under the cwd root is fine.
    try allowed(alloc, fs, "/wd/f.txt");
    try allowed(alloc, fs, "/wd/./f.txt"); // interior `.` collapses
}

test "confine detects a symlink escape via realpath and fails closed (A2)" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const abs = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(abs);

    var impl = @import("../fs/fs.zig").RealFs.init(abs);
    const fs = impl.toFs();

    // A symlink inside the workspace pointing at a real location outside it.
    try tmp.dir.symLink("/etc", "esc", .{});
    try refusal(alloc, fs, "esc/hosts");
    try refusal(alloc, fs, "/etc/hosts");

    // In-root real file passes (write parent check path exercised too).
    try tmp.dir.writeFile(.{ .sub_path = "ok.txt", .data = "x" });
    try allowed(alloc, fs, "ok.txt");
    try allowed(alloc, fs, "new/nested.txt"); // missing file: lexical + parent check only
}
