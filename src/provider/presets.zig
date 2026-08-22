const std = @import("std");
const Allocator = std.mem.Allocator;
const provider = @import("provider.zig");
const OpenAIProvider = @import("openai.zig").OpenAIProvider;
const Transport = @import("transport.zig").Transport;

/// The five required providers (FR-004). Each is a config-driven
/// OpenAIProvider instance — one client, five presets, zero branching (OCP).
/// Endpoints/models are defaults; config overrides them (FR-005).
pub const Preset = struct {
    name: []const u8,
    default_endpoint: []const u8,
    default_model: []const u8,
};

pub const PRESETS = [_]Preset{
    .{ .name = "opencode", .default_endpoint = "http://localhost:4099/v1", .default_model = "opencode" },
    .{ .name = "kilo", .default_endpoint = "https://api.kilo.ai/v1", .default_model = "kilo-1" },
    .{ .name = "zai", .default_endpoint = "https://api.z.ai/v1", .default_model = "glm-4.5-air" },
    .{ .name = "kimi", .default_endpoint = "https://api.moonshot.cn/v1", .default_model = "kimi-k2-0711" },
    .{ .name = "openai_custom", .default_endpoint = "https://api.openai.com/v1", .default_model = "gpt-4o-mini" },
    .{ .name = "cliproxy", .default_endpoint = "http://localhost:8317/v1", .default_model = "mimo-v2.5" },
};

pub fn findPreset(name: []const u8) ?Preset {
    for (PRESETS) |p| {
        if (std.mem.eql(u8, p.name, name)) return p;
    }
    return null;
}

/// Build a Provider for one of the five names. endpoint/model override the
/// preset defaults when non-empty; api_key is required for hosted providers.
///
/// Returns the provider struct **by value**: the caller must keep the result in
/// a `var` and derive the `Provider` interface from it, otherwise the vtable's
/// `ctx` would point at a dangling stack slot (the provider holds no heap state
/// beyond the slices the caller already owns).
pub fn build(
    alloc: Allocator,
    name: []const u8,
    endpoint_override: []const u8,
    model_override: []const u8,
    api_key: []const u8,
    transport: Transport,
) !OpenAIProvider {
    const preset = findPreset(name) orelse return error.UnknownProvider;
    const endpoint = if (endpoint_override.len > 0) endpoint_override else preset.default_endpoint;
    const model = if (model_override.len > 0) model_override else preset.default_model;
    return OpenAIProvider.init(alloc, preset.name, endpoint, model, api_key, transport);
}

test "presets cover exactly the five required providers" {
    try std.testing.expectEqual(@as(usize, 6), PRESETS.len);
    try std.testing.expect(findPreset("kimi") != null);
    try std.testing.expect(findPreset("openai_custom") != null);
    try std.testing.expect(findPreset("anthropic") == null);
    try std.testing.expectError(error.UnknownProvider, build(std.testing.allocator, "anthropic", "", "", "", Transport{ .ctx = undefined, .vtable = undefined }));
}
