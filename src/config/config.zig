const std = @import("std");
const Allocator = std.mem.Allocator;
const compat = @import("../compat.zig");
const presets = @import("../provider/presets.zig");

/// Resolved provider configuration (FR-005). Loaded from environment then
/// optionally a config file; only the five required providers are accepted.
pub const Config = struct {
    active_provider: []const u8,
    endpoint: []const u8,
    model: []const u8,
    api_key: []const u8,
    /// Optional proxy URL. Empty means "no proxy" (direct connection). When set,
    /// all provider requests are routed through it (spec 009).
    proxy: []const u8,

    pub fn isValid(self: Config) bool {
        return presets.findPreset(self.active_provider) != null;
    }

    /// Frees the heap-owned fields produced by `load`.
    pub fn deinit(self: Config, alloc: Allocator) void {
        alloc.free(self.active_provider);
        alloc.free(self.endpoint);
        alloc.free(self.model);
        alloc.free(self.api_key);
        alloc.free(self.proxy);
    }
};

/// Load configuration prioritizing environment variables, then config file
/// `~/.config/ziki/config.json`. Returns an error if no valid provider is set.
pub fn load(alloc: Allocator) !Config {
    const env = compat.envMap() catch return error.ConfigError;
    // A missing HOME just means "no config file" — loadFile tolerates an empty
    // home (the fixture path won't exist), same as the old behavior.
    const home = (compat.getEnvOwned(alloc, "HOME") catch null) orelse "";
    defer if (home.len > 0) alloc.free(home);
    return loadFrom(alloc, home, env);
}

/// Testable core of `load`: env vars win over `<home>/.config/ziki/config.json`,
/// with the environment passed explicitly so tests never mutate the process env.
pub fn loadFrom(alloc: Allocator, home: []const u8, env: *const std.process.Environ.Map) !Config {
    var provider: []const u8 = "";
    var endpoint: []const u8 = "";
    var model: []const u8 = "";
    var api_key: []const u8 = "";
    var proxy: []const u8 = "";

    if (env.get("ZIKI_PROVIDER")) |v| provider = v;
    if (env.get("ZIKI_ENDPOINT")) |v| endpoint = v;
    if (env.get("ZIKI_MODEL")) |v| model = v;
    if (env.get("ZIKI_API_KEY")) |v| api_key = v;
    if (env.get("ZIKI_PROXY")) |v| proxy = v;

    // Config file overrides only when an env var is empty.
    const ov = loadFile(alloc, home) catch FileOverrides{};
    defer {
        alloc.free(ov.provider);
        alloc.free(ov.endpoint);
        alloc.free(ov.model);
        alloc.free(ov.api_key);
        alloc.free(ov.proxy);
    }
    provider = resolve(provider, ov.provider);
    endpoint = resolve(endpoint, ov.endpoint);
    model = resolve(model, ov.model);
    api_key = resolve(api_key, ov.api_key);
    proxy = resolve(proxy, ov.proxy);

    if (provider.len == 0) return error.NoProviderConfigured;
    if (presets.findPreset(provider) == null) return error.UnknownProvider;

    return Config{
        .active_provider = try alloc.dupe(u8, provider),
        .endpoint = try alloc.dupe(u8, endpoint),
        .model = try alloc.dupe(u8, model),
        .api_key = try alloc.dupe(u8, api_key),
        .proxy = try alloc.dupe(u8, proxy),
    };
}

/// Optional overrides read from `~/.config/ziki/config.json`. Each field is a
/// heap copy (owned by the caller) or empty when unset.
const FileOverrides = struct {
    provider: []const u8 = "",
    endpoint: []const u8 = "",
    model: []const u8 = "",
    api_key: []const u8 = "",
    proxy: []const u8 = "",
};

fn loadFile(alloc: Allocator, home: []const u8) !FileOverrides {
    const path = try std.fmt.allocPrint(alloc, "{s}/.config/ziki/config.json", .{home});
    defer alloc.free(path);
    const raw = std.Io.Dir.cwd().readFileAlloc(compat.io(), path, alloc, .limited(1 << 20)) catch return error.FileNotFound;
    defer alloc.free(raw);

    const Cfg = struct {
        active_provider: ?[]const u8,
        endpoint: ?[]const u8,
        model: ?[]const u8,
        api_key: ?[]const u8,
        proxy: ?[]const u8 = null,
    };
    var parsed = std.json.parseFromSlice(Cfg, alloc, raw, .{ .ignore_unknown_fields = true }) catch return error.BadJson;
    defer parsed.deinit();
    const c = parsed.value;
    return FileOverrides{
        .provider = if (c.active_provider) |v| try alloc.dupe(u8, v) else "",
        .endpoint = if (c.endpoint) |v| try alloc.dupe(u8, v) else "",
        .model = if (c.model) |v| try alloc.dupe(u8, v) else "",
        .api_key = if (c.api_key) |v| try alloc.dupe(u8, v) else "",
        .proxy = if (c.proxy) |v| try alloc.dupe(u8, v) else "",
    };
}

/// Environment value wins over the file value; empty means "unset".
fn resolve(over: []const u8, under: []const u8) []const u8 {
    return if (over.len > 0) over else under;
}

test "load rejects unknown provider" {
    const alloc = std.testing.allocator;
    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    try env.put("ZIKI_PROVIDER", "anthropic");
    try std.testing.expectError(error.UnknownProvider, loadFrom(alloc, "", &env));

    var empty = std.process.Environ.Map.init(alloc);
    defer empty.deinit();
    try std.testing.expectError(error.NoProviderConfigured, loadFrom(alloc, "", &empty));
}

test "proxy precedence: env overrides file; malformed carried verbatim" {
    // resolve(over, under): env (over) wins when non-empty; file (under) otherwise.
    try std.testing.expectEqualStrings("env", resolve("env", "file"));
    try std.testing.expectEqualStrings("file", resolve("", "file"));
    // A malformed proxy is carried verbatim; the transport rejects it at startup.
    try std.testing.expectEqualStrings("not-a-url", resolve("not-a-url", ""));
}

test "load exposes proxy from config/env without mutating env" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try compat.tmpDirPath(alloc, &tmp);
    defer alloc.free(home);

    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    try env.put("ZIKI_PROVIDER", "kimi");
    try env.put("ZIKI_PROXY", "http://proxy.example.com:8080");

    // Runs the real env/file resolution through loadFrom — a regression in
    // load()'s proxy handling now fails here instead of passing green.
    const cfg = try loadFrom(alloc, home, &env);
    defer cfg.deinit(alloc);
    try std.testing.expectEqualStrings("kimi", cfg.active_provider);
    try std.testing.expectEqualStrings("http://proxy.example.com:8080", cfg.proxy);
}

test "load falls back to the config file proxy when the env leaves it unset" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(compat.io(), ".config/ziki");
    try tmp.dir.writeFile(compat.io(), .{
        .sub_path = ".config/ziki/config.json",
        .data = "{\"active_provider\": \"kimi\", \"endpoint\": \"\", \"model\": \"\", \"api_key\": \"\", \"proxy\": \"http://file-proxy.example.com:3128\"}",
    });
    const home = try compat.tmpDirPath(alloc, &tmp);
    defer alloc.free(home);

    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    try env.put("ZIKI_PROVIDER", "kimi");

    const cfg = try loadFrom(alloc, home, &env);
    defer cfg.deinit(alloc);
    try std.testing.expectEqualStrings("http://file-proxy.example.com:3128", cfg.proxy);
}

test "config proxy is empty (direct connection) when env and file leave it unset" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(compat.io(), ".config/ziki");
    try tmp.dir.writeFile(compat.io(), .{
        .sub_path = ".config/ziki/config.json",
        .data = "{\"active_provider\": \"kimi\", \"endpoint\": \"\", \"model\": \"\", \"api_key\": \"\"}",
    });
    const home = try compat.tmpDirPath(alloc, &tmp);
    defer alloc.free(home);

    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    try env.put("ZIKI_PROVIDER", "kimi");

    const cfg = try loadFrom(alloc, home, &env);
    defer cfg.deinit(alloc);
    try std.testing.expectEqualStrings("", cfg.proxy);
}
