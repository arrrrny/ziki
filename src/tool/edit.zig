const std = @import("std");
const Allocator = std.mem.Allocator;
const Tool = @import("tool.zig").Tool;
const ToolResult = @import("tool.zig").ToolResult;
const ToolSpec = @import("../provider/provider.zig").ToolSpec;
const Fs = @import("../fs/fs.zig").Fs;

pub const EditTool = struct {
    fs: Fs,

    pub fn init(fs: Fs) EditTool {
        return .{ .fs = fs };
    }
    pub fn toTool(self: *EditTool) Tool {
        return .{ .ctx = self, .vtable = &vtable };
    }
    const vtable = Tool.VTable{ .execute = execute, .schema = schema, .name = name };

    fn name(_: *anyopaque) []const u8 {
        return "edit_file";
    }
    fn schema(_: *anyopaque) ToolSpec {
        return .{
            .name = "edit_file",
            .description = "Edit a file by `mode`: `replace` swaps the first occurrence of `old` with `new` (fails unless found exactly once), `create` makes a missing file with `new` as its content, `delete` removes the file.",
            .parameters_json_schema =
            \\{"type":"object","properties":{"path":{"type":"string"},"old":{"type":"string"},"new":{"type":"string"},"mode":{"type":"string","enum":["replace","create","delete"]}},"required":["path","mode","new"]}
            ,
        };
    }
    fn execute(ctx: *anyopaque, alloc: Allocator, args_json: []const u8) !ToolResult {
        const self: *EditTool = @ptrCast(@alignCast(ctx));
        const Args = struct { path: []const u8, old: []const u8 = "", new: []const u8 = "", mode: []const u8 = "replace" };
        var parsed = try std.json.parseFromSlice(Args, alloc, args_json, .{});
        defer parsed.deinit();

        // Spec 015: structured refusal before any file access (fail closed).
        if (@import("confine.zig").check(alloc, self.fs, parsed.value.path)) |msg| {
            return ToolResult{ .ok = false, .error_message = msg };
        }

        const mode = parsed.value.mode;
        if (std.mem.eql(u8, mode, "create")) {
            if (self.fs.exists(parsed.value.path)) {
                return ToolResult{ .ok = false, .error_message = try std.fmt.allocPrint(alloc, "edit_file create: already exists: {s}", .{parsed.value.path}) };
            }
            self.fs.writeFile(alloc, parsed.value.path, parsed.value.new) catch |e| {
                return ToolResult{ .ok = false, .error_message = try std.fmt.allocPrint(alloc, "edit_file create failed: {s}", .{@errorName(e)}) };
            };
            return ToolResult{ .ok = true, .output = try std.fmt.allocPrint(alloc, "created {s}", .{parsed.value.path}) };
        }
        if (std.mem.eql(u8, mode, "delete")) {
            self.fs.remove(parsed.value.path) catch |e| {
                const msg = if (e == error.FileNotFound)
                    try std.fmt.allocPrint(alloc, "edit_file delete: not found: {s}", .{parsed.value.path})
                else
                    try std.fmt.allocPrint(alloc, "edit_file delete failed: {s}", .{@errorName(e)});
                return ToolResult{ .ok = false, .error_message = msg };
            };
            return ToolResult{ .ok = true, .output = try std.fmt.allocPrint(alloc, "deleted {s}", .{parsed.value.path}) };
        }
        if (!std.mem.eql(u8, mode, "replace")) {
            return ToolResult{ .ok = false, .error_message = try std.fmt.allocPrint(alloc, "edit_file: unknown mode: {s}", .{mode}) };
        }
        // The schema requires `old` for replace; the Args default must not let
        // an omitted `old` silently "match" position 0 of an empty file.
        if (parsed.value.old.len == 0) {
            return ToolResult{ .ok = false, .error_message = try std.fmt.allocPrint(alloc, "edit_file replace: `old` is required", .{}) };
        }

        const original = self.fs.readFile(alloc, parsed.value.path) catch |e| {
            return ToolResult{ .ok = false, .error_message = try std.fmt.allocPrint(alloc, "edit_file read failed: {s}", .{@errorName(e)}) };
        };
        defer alloc.free(original);

        const count = std.mem.count(u8, original, parsed.value.old);
        if (count != 1) {
            return ToolResult{ .ok = false, .error_message = try std.fmt.allocPrint(alloc, "edit_file expected exactly 1 match, found {d}", .{count}) };
        }
        const replaced = try std.mem.replaceOwned(u8, alloc, original, parsed.value.old, parsed.value.new);
        defer alloc.free(replaced);
        self.fs.writeFile(alloc, parsed.value.path, replaced) catch |e| {
            return ToolResult{ .ok = false, .error_message = try std.fmt.allocPrint(alloc, "edit_file write failed: {s}", .{@errorName(e)}) };
        };
        return ToolResult{ .ok = true, .output = try std.fmt.allocPrint(alloc, "edited {s}", .{parsed.value.path}) };
    }
};

test "EditTool replaces exactly once" {
    var fake = @import("../fs/fs.zig").FakeFs.init(std.testing.allocator, "/wd");
    defer fake.deinit();
    try fake.writeFile(std.testing.allocator, "f.txt", "hello world");
    var et = EditTool.init(fake.toFs());
    const t = et.toTool();
    const r = try t.execute(std.testing.allocator, "{\"path\":\"f.txt\",\"old\":\"world\",\"new\":\"ziki\"}");
    defer std.testing.allocator.free(r.output);
    try std.testing.expect(r.ok);
    const got = try fake.readFile(std.testing.allocator, "f.txt");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("hello ziki", got);
}

// Issue #18 (Lane C): create-if-missing and delete modes.
test "EditTool create mode makes a missing file and refuses an existing one (A4)" {
    const alloc = std.testing.allocator;
    var fake = @import("../fs/fs.zig").FakeFs.init(alloc, "/wd");
    defer fake.deinit();
    var et = EditTool.init(fake.toFs());
    const t = et.toTool();

    // Missing path: created with `new` as content.
    const r = try t.execute(alloc, "{\"path\":\"new.txt\",\"mode\":\"create\",\"new\":\"fresh\"}");
    defer alloc.free(r.output);
    try std.testing.expect(r.ok);
    const got = try fake.readFile(alloc, "new.txt");
    defer alloc.free(got);
    try std.testing.expectEqualStrings("fresh", got);

    // Existing path: structured refusal, content untouched.
    const r2 = try t.execute(alloc, "{\"path\":\"new.txt\",\"mode\":\"create\",\"new\":\"clobber\"}");
    defer alloc.free(r2.error_message.?);
    try std.testing.expect(!r2.ok);
    try std.testing.expect(std.mem.indexOf(u8, r2.error_message.?, "already exists") != null);
    const again = try fake.readFile(alloc, "new.txt");
    defer alloc.free(again);
    try std.testing.expectEqualStrings("fresh", again);
}

test "EditTool delete mode removes a file and refuses a missing one (A4)" {
    const alloc = std.testing.allocator;
    var fake = @import("../fs/fs.zig").FakeFs.init(alloc, "/wd");
    defer fake.deinit();
    try fake.writeFile(alloc, "gone.txt", "bye");
    var et = EditTool.init(fake.toFs());
    const t = et.toTool();

    const r = try t.execute(alloc, "{\"path\":\"gone.txt\",\"mode\":\"delete\"}");
    defer alloc.free(r.output);
    try std.testing.expect(r.ok);
    try std.testing.expect(!fake.toFs().exists("gone.txt"));

    const r2 = try t.execute(alloc, "{\"path\":\"gone.txt\",\"mode\":\"delete\"}");
    defer alloc.free(r2.error_message.?);
    try std.testing.expect(!r2.ok);
    try std.testing.expect(std.mem.indexOf(u8, r2.error_message.?, "not found") != null);
}

// Review hardening: replace mode must not treat an omitted `old` (the Args
// default "") as a 1-count match on an empty file.
test "EditTool replace mode refuses an empty `old`" {
    const alloc = std.testing.allocator;
    var fake = @import("../fs/fs.zig").FakeFs.init(alloc, "/wd");
    defer fake.deinit();
    try fake.writeFile(alloc, "empty.txt", "");
    var et = EditTool.init(fake.toFs());
    const t = et.toTool();
    const r = try t.execute(alloc, "{\"path\":\"empty.txt\",\"mode\":\"replace\",\"new\":\"x\"}");
    defer alloc.free(r.error_message.?);
    try std.testing.expect(!r.ok);
    try std.testing.expect(std.mem.indexOf(u8, r.error_message.?, "old") != null);
}
