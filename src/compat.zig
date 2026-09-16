//! Zig 0.16 platform shims (spec 018, issue #21).
//!
//! 0.16 threads an explicit `Io` capability through every I/O operation and
//! removes the process-global environment accessors. This module owns that
//! state for both entry points:
//!
//! - CLI: `main(env)` calls `init(env)` once.
//! - Tests: `std.testing` provides the Io instance and environ; `io()` and
//!   `getEnvOwned` reach them lazily.

const std = @import("std");
const builtin = @import("builtin");

var main_io: std.Io = undefined;
var have_main_io = false;
var env_map: ?std.process.Environ.Map = null;
var env_ready = false;

/// Called once from `main` with the environment provided by start.zig.
pub fn init(env: std.process.Init) void {
    main_io = env.io;
    have_main_io = true;
    env_map = env.environ_map.*;
    env_ready = true;
}

/// The process Io instance. In tests this is the runner-initialized one.
pub fn io() std.Io {
    if (comptime builtin.is_test) {
        return std.testing.io;
    }
    std.debug.assert(have_main_io); // main() must call compat.init first
    return main_io;
}

/// Milliseconds since the Unix epoch (replaces the removed
/// `std.time.milliTimestamp`).
pub fn milliTimestamp() i64 {
    return std.Io.Timestamp.now(io(), .real).toMilliseconds();
}

/// Seconds since the Unix epoch (replaces the removed `std.time.timestamp`).
pub fn timestamp() i64 {
    return std.Io.Timestamp.now(io(), .real).toSeconds();
}

/// Nanoseconds since the Unix epoch (replaces the removed
/// `std.time.nanoTimestamp`).
pub fn nanoTimestamp() i96 {
    return std.Io.Timestamp.now(io(), .real).toNanoseconds();
}

/// Sleep for `ms` milliseconds on the monotonic clock (replaces the removed
/// `std.Thread.sleep`). Cancel cannot fire without an enclosing cancel scope.
pub fn sleepMs(ms: i64) void {
    io().sleep(std.Io.Duration.fromMilliseconds(ms), .awake) catch {};
}

/// Mirror of the removed `std.process.getEnvVarOwned`: returns an owned copy
/// of the variable's value, or null when unset.
pub fn getEnvOwned(alloc: std.mem.Allocator, name: []const u8) !?[]u8 {
    if (!env_ready) try initEnvMap();
    const v = env_map.?.get(name) orelse return null;
    return try alloc.dupe(u8, v);
}

/// Non-owning lookup (0.16 `Environ.Map.get`).
pub fn getenv(name: []const u8) ?[]const u8 {
    if (!env_ready) initEnvMap() catch return null;
    return env_map.?.get(name);
}

fn initEnvMap() !void {
    const gpa = std.heap.page_allocator;
    if (comptime builtin.is_test) {
        env_map = try std.process.Environ.createMap(std.testing.environ, gpa);
    } else {
        // Non-test builds initialize via init(env); this path only exists to
        // keep the compiler happy when compat is linked without main.
        return error.EnvironUnavailable;
    }
    env_ready = true;
}

/// The process environment as a 0.16 `Environ.Map` (lazily built in tests,
/// captured by `init(env)` in production). The map is valid for the life of
/// the process; callers must not deinit it.
pub fn envMap() !*const std.process.Environ.Map {
    if (!env_ready) try initEnvMap();
    return &env_map.?;
}

/// Absolute path of the testing tmp dir created by `std.testing.tmpDir`.
///
/// 0.16 dropped `Dir.realpathAlloc`, and `std.testing.TmpDir` exposes only its
/// `dir` handle — but its fixed layout is `cwd()/.zig-cache/tmp/<sub_path>`
/// (see `std.testing.tmpDir`), so the absolute path can be reconstructed
/// without any realpath syscall. Caller owns the returned slice.
pub fn tmpDirPath(alloc: std.mem.Allocator, tmp: *std.testing.TmpDir) ![]u8 {
    const cwd = try std.process.currentPathAlloc(io(), alloc);
    defer alloc.free(cwd);
    return std.fs.path.join(alloc, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
}

test "getEnvOwned finds a set variable" {
    // PATH is set in every environment the suite runs in.
    const path = (try getEnvOwned(std.testing.allocator, "PATH")) orelse return;
    defer std.testing.allocator.free(path);
    try std.testing.expect(path.len > 0);
}

test "getEnvOwned returns null for a definitely-unset variable" {
    if (comptime builtin.is_test) {
        const v = try getEnvOwned(std.testing.allocator, "ZIKI_NO_SUCH_VAR_COMPAT_TEST");
        try std.testing.expect(v == null);
    }
}
