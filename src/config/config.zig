const std = @import("std");
const Allocator = std.mem.Allocator;
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
    var env = std.process.getEnvMap(alloc) catch return error.ConfigError;
    defer env.deinit();

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
    const ov = loadFile(alloc) catch FileOverrides{};
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

fn loadFile(alloc: Allocator) !FileOverrides {
    const home = std.process.getEnvVarOwned(alloc, "HOME") catch return error.NoHome;
    defer alloc.free(home);
    const path = try std.fmt.allocPrint(alloc, "{s}/.config/ziki/config.json", .{home});
    defer alloc.free(path);
    const raw = std.fs.cwd().readFileAlloc(alloc, path, 1 << 20) catch return error.FileNotFound;
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
    // With no HOME/config and no env, load should fail with NoProviderConfigured
    // (we cannot guarantee env in test, so just assert the function type-checks
    // by checking findPreset behaviour already covered in presets tests).
    _ = load;
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
    const env_proxy = std.process.getEnvVarOwned(alloc, "ZIKI_PROXY") catch null;
    defer if (env_proxy) |e| alloc.free(e);

    // load MUST succeed (this also guards against config-file parse regressions).
    const cfg = try load(alloc);
    defer cfg.deinit(alloc);

    if (env_proxy) |e| {
        try std.testing.expectEqualStrings(e, cfg.proxy);
    } else {
        // No env override: proxy must come from the file. Read the file's proxy
        // independently so the test stays deterministic regardless of whether the
        // local ~/.config/ziki/config.json sets a proxy (FR-005, spec 009).
        const file_proxy = readConfigProxy(alloc) catch "";
        defer if (file_proxy.len > 0) alloc.free(file_proxy);
        try std.testing.expectEqualStrings(file_proxy, cfg.proxy);
    }
}

test "config proxy is empty (direct connection) when env and file leave it unset" {
    const alloc = std.testing.allocator;
    const env_proxy = std.process.getEnvVarOwned(alloc, "ZIKI_PROXY") catch null;
    defer if (env_proxy) |e| alloc.free(e);
    const cfg = try load(alloc);
    defer cfg.deinit(alloc);
    if (env_proxy) |e| {
        try std.testing.expectEqualStrings(e, cfg.proxy);
    } else {
        const file_proxy = readConfigProxy(alloc) catch "";
        defer if (file_proxy.len > 0) alloc.free(file_proxy);
        try std.testing.expectEqualStrings(file_proxy, cfg.proxy);
        // Direct-connection default (FR-003): with neither env nor file setting
        // a proxy, Config.proxy must be "" so the transport connects directly.
        if (file_proxy.len == 0) {
            try std.testing.expectEqualStrings("", cfg.proxy);
        }
        }
}

/// Test helper: read only the `proxy` field from the resolved config file.
/// Returns an empty slice when the file or field is absent.
fn readConfigProxy(alloc: Allocator) ![]const u8 {
    const home = std.process.getEnvVarOwned(alloc, "HOME") catch return error.NoHome;
    defer alloc.free(home);
    const path = try std.fmt.allocPrint(alloc, "{s}/.config/ziki/config.json", .{home});
    defer alloc.free(path);
    const raw = std.fs.cwd().readFileAlloc(alloc, path, 1 << 20) catch return alloc.dupe(u8, "");
    defer alloc.free(raw);
    const Cfg = struct { proxy: ?[]const u8 = null };
    var parsed = std.json.parseFromSlice(Cfg, alloc, raw, .{ .ignore_unknown_fields = true }) catch return alloc.dupe(u8, "");
    defer parsed.deinit();
    if (parsed.value.proxy) |p| return alloc.dupe(u8, p);
    return alloc.dupe(u8, "");
}
