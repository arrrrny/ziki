const std = @import("std");
const Allocator = std.mem.Allocator;
const Tool = @import("tool.zig").Tool;
const ToolResult = @import("tool.zig").ToolResult;
const ToolSpec = @import("../provider/provider.zig").ToolSpec;
const Fs = @import("../fs/fs.zig").Fs;

/// Substring search within a file (MVP parity with Kimi's grep for the common
/// case). Returns matching line numbers and the matched lines.
pub const SearchTool = struct {
    fs: Fs,

    pub fn init(fs: Fs) SearchTool {
        return .{ .fs = fs };
    }
    pub fn toTool(self: *SearchTool) Tool {
        return .{ .ctx = self, .vtable = &vtable };
    }
    const vtable = Tool.VTable{ .execute = execute, .schema = schema, .name = name };

    fn name(_: *anyopaque) []const u8 {
        return "search_file";
    }
    fn schema(_: *anyopaque) ToolSpec {
        return .{
            .name = "search_file",
            .description = "Find lines containing the given substring, in `path` (single file) or recursively under `dir` (bounded by `max_files`).",
            .parameters_json_schema =
                \\{"type":"object","properties":{"path":{"type":"string"},"pattern":{"type":"string"},"dir":{"type":"string"},"max_files":{"type":"integer","minimum":1,"maximum":256}},"required":["pattern"],"anyOf":[{"required":["path"]},{"required":["dir"]}]}
            ,
        };
    }
    fn execute(ctx: *anyopaque, alloc: Allocator, args_json: []const u8) !ToolResult {
        const self: *SearchTool = @ptrCast(@alignCast(ctx));
        const Args = struct { path: []const u8 = "", pattern: []const u8, dir: []const u8 = "", max_files: u32 = 256 };
        var parsed = try std.json.parseFromSlice(Args, alloc, args_json, .{});
        defer parsed.deinit();

        var out = try std.ArrayList(u8).initCapacity(alloc, 0);

        // Spec 015: recursive directory search with a bounded file count.
        if (parsed.value.dir.len > 0) {
            if (@import("confine.zig").check(alloc, self.fs, parsed.value.dir)) |msg| {
                return ToolResult{ .ok = false, .error_message = msg };
            }
            // FR-004: 256 is a hard cap, whatever the model sends.
            var budget: usize = @min(parsed.value.max_files, 256);
            var noticed = false;
            try walkSearch(alloc, self.fs, parsed.value.dir, parsed.value.pattern, &budget, &noticed, &out, 0);
            return ToolResult{ .ok = true, .output = try out.toOwnedSlice(alloc) };
        }

        // Spec 015: structured refusal before any file access (fail closed).
        if (@import("confine.zig").check(alloc, self.fs, parsed.value.path)) |msg| {
            return ToolResult{ .ok = false, .error_message = msg };
        }

        const content = self.fs.readFile(alloc, parsed.value.path) catch |e| {
            return ToolResult{ .ok = false, .error_message = try std.fmt.allocPrint(alloc, "search_file read failed: {s}", .{@errorName(e)}) };
        };
        defer alloc.free(content);

        var line_iter = std.mem.splitScalar(u8, content, '\n');
        var line_no: usize = 0;
        while (line_iter.next()) |line| {
            line_no += 1;
            if (std.mem.indexOf(u8, line, parsed.value.pattern) != null) {
                try std.fmt.format(out.writer(alloc), "{d}: {s}\n", .{ line_no, line });
            }
        }
        return ToolResult{ .ok = true, .output = try out.toOwnedSlice(alloc) };
    }
};

/// Search one file under `path`; returns false when `path` is not a readable
/// file (the caller then treats it as a directory and recurses). Decrements
/// `budget` per file actually opened; never opens anything once it hits zero
/// (the walk then stops and emits the limit notice once).
fn searchOneFile(alloc: Allocator, fs: Fs, path: []const u8, pattern: []const u8, budget: *usize, out: *std.ArrayList(u8)) !bool {
    if (budget.* == 0) return true;
    const content = fs.readFile(alloc, path) catch return false;
    defer alloc.free(content);
    budget.* -= 1;
    var line_iter = std.mem.splitScalar(u8, content, '\n');
    var line_no: usize = 0;
    while (line_iter.next()) |line| {
        line_no += 1;
        if (std.mem.indexOf(u8, line, pattern) != null) {
            try std.fmt.format(out.writer(alloc), "{s}:{d}: {s}\n", .{ path, line_no, line });
        }
    }
    return true;
}

fn walkSearch(alloc: Allocator, fs: Fs, dir: []const u8, pattern: []const u8, budget: *usize, noticed: *bool, out: *std.ArrayList(u8), depth: usize) !void {
    // Depth cap: an in-root symlink cycle (a→b→a) must not recurse forever.
    if (depth > 32) return;
    const entries = fs.readDir(alloc, dir) catch return;
    defer {
        for (entries) |e| alloc.free(e);
        alloc.free(entries);
    }
    for (entries) |e| {
        if (budget.* == 0) {
            // One-shot notice, then stop walking entirely.
            if (!noticed.*) {
                try out.appendSlice(alloc, "[search_file: file limit reached]\n");
                noticed.* = true;
            }
            break;
        }
        const child = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir, e });
        defer alloc.free(child);
        // Fail closed: the walk must not read what confinement refuses.
        if (@import("confine.zig").check(alloc, fs, child)) |msg| {
            alloc.free(msg);
            continue;
        }
        if (try searchOneFile(alloc, fs, child, pattern, budget, out)) continue;
        try walkSearch(alloc, fs, child, pattern, budget, noticed, out, depth + 1);
    }
}

test "SearchTool finds matching lines" {
    var fake = @import("../fs/fs.zig").FakeFs.init(std.testing.allocator, "/wd");
    defer fake.deinit();
    try fake.writeFile(std.testing.allocator, "f.txt", "foo\nbar baz\nqux");
    var st = SearchTool.init(fake.toFs());
    const t = st.toTool();
    const r = try t.execute(std.testing.allocator, "{\"path\":\"f.txt\",\"pattern\":\"baz\"}");
    defer std.testing.allocator.free(r.output);
    try std.testing.expect(r.ok);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "2: bar baz") != null);
}

// Issue #18 (Lane C): recursive directory search with a file-count bound.
test "SearchTool searches a directory recursively with a bound (A5)" {
    const alloc = std.testing.allocator;
    var fake = @import("../fs/fs.zig").FakeFs.init(alloc, "/wd");
    defer fake.deinit();
    try fake.writeFile(alloc, "src/a.zig", "const needle = 1;\nother\n");
    try fake.writeFile(alloc, "src/sub/b.zig", "x\nneedle here\n");
    try fake.writeFile(alloc, "docs/c.md", "needle in docs\n");
    var st = SearchTool.init(fake.toFs());
    const t = st.toTool();

    // Recursive: hits every file under src/, skips docs/ (outside the dir).
    const r = try t.execute(alloc, "{\"dir\":\"src\",\"pattern\":\"needle\"}");
    defer alloc.free(r.output);
    try std.testing.expect(r.ok);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "src/a.zig:1: const needle = 1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "src/sub/b.zig:2: needle here") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "docs/c.md") == null);

    // Bound: max_files=1 examines only the first file (sorted order: a.zig).
    const r2 = try t.execute(alloc, "{\"dir\":\"src\",\"pattern\":\"needle\",\"max_files\":1}");
    defer alloc.free(r2.output);
    try std.testing.expect(std.mem.indexOf(u8, r2.output, "src/a.zig:1:") != null);
    try std.testing.expect(std.mem.indexOf(u8, r2.output, "src/sub/b.zig") == null);
    try std.testing.expect(std.mem.indexOf(u8, r2.output, "file limit") != null);
}

// Review hardening: the dir walk is confined like the single-file path — a
// symlinked child pointing outside the root is skipped entirely, and an
// in-root symlink cycle terminates via the depth cap instead of overflowing
// the stack.
test "SearchTool dir walk skips symlink escapes and survives symlink cycles" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const abs = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(abs);

    var impl = @import("../fs/fs.zig").RealFs.init(abs);
    var st = SearchTool.init(impl.toFs());
    const t = st.toTool();

    try tmp.dir.makePath("src");
    try tmp.dir.writeFile(.{ .sub_path = "src/real.zig", .data = "needle here\n" });
    try tmp.dir.symLink("/etc", "src/esc", .{}); // escape: refused, never read
    try tmp.dir.symLink(".", "src/loop", .{}); // in-root cycle: depth-capped

    const r = try t.execute(alloc, "{\"dir\":\"src\",\"pattern\":\"needle\"}");
    defer alloc.free(r.output);
    try std.testing.expect(r.ok);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "src/real.zig:1: needle here") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "hosts") == null);
}
