// Test aggregator. Importing each module pulls in its `test` declarations so
// `zig build test` runs the whole suite. Add executor/cli/main as they land.
const std = @import("std");
const fs = @import("src/fs/fs.zig");
const goal = @import("src/goal/goal.zig");
const repository = @import("src/goal/repository.zig");
const provider = @import("src/provider/provider.zig");
const transport = @import("src/provider/transport.zig");
const openai = @import("src/provider/openai.zig");
const fake = @import("src/provider/fake.zig");
const presets = @import("src/provider/presets.zig");
const tool = @import("src/tool/tool.zig");
const read = @import("src/tool/read.zig");
const edit = @import("src/tool/edit.zig");
const search = @import("src/tool/search.zig");
const bash = @import("src/tool/bash.zig");
const write = @import("src/tool/write.zig");
const executor = @import("src/agent/executor.zig");
const state_sync = @import("src/agent/state_sync_test.zig");
const state = @import("src/agent/state.zig");
const herdr = @import("src/agent/herdr.zig");
const main_mod = @import("src/main.zig");
const config = @import("src/config/config.zig");
const shell_test = @import("src/shell/shell_test.zig");
const skill = @import("src/skill/skill.zig");
const skill_registry = @import("src/skill/registry.zig");
const skill_tool = @import("src/skill/tool.zig");
const skill_handler = @import("src/skill/handler.zig");

test "aggregator loads all modules" {
    _ = std.testing;
    _ = fs;
    _ = goal;
    _ = repository;
    _ = provider;
    _ = transport;
    _ = openai;
    _ = fake;
    _ = presets;
    _ = tool;
    _ = read;
    _ = edit;
    _ = search;
    _ = bash;
    _ = write;
    _ = executor;
    _ = state_sync;
    _ = state;
    _ = herdr;
    _ = main_mod;
    _ = config;
    _ = skill;
    _ = skill_registry;
    _ = skill_tool;
    _ = skill_handler;
}
