//! Skill-driven end-to-end goal test (issue #20 feature work, spec 009-skill-system).
//!
//! Full loop: a skill is loaded from a real on-disk root (tmpDir + RealFs) →
//! the registry's listing appears in the system prompt → the scripted provider
//! fetches it via the `skill` tool → the executor writes the artifact through
//! `write_file`. Doubles: FakeProvider-style scripting + FakeFs for goal state;
//! the only real I/O is the tmpDir skill root.

const std = @import("std");
const Allocator = std.mem.Allocator;
const provider = @import("../provider/provider.zig");
const Tool = @import("../tool/tool.zig").Tool;
const registry_mod = @import("registry.zig");
const SkillRegistry = registry_mod.SkillRegistry;
const SkillTool = @import("tool.zig").SkillTool;
const WriteTool = @import("../tool/write.zig").WriteTool;
const GoalExecutor = @import("../agent/executor.zig").GoalExecutor;
const Goal = @import("../goal/goal.zig").Goal;
const FsGoalRepository = @import("../goal/repository.zig").FsGoalRepository;
const FakeFs = @import("../fs/fs.zig").FakeFs;
const RealFs = @import("../fs/fs.zig").RealFs;

/// Scripted provider that also records the system prompt of every request, so
/// the test can assert the skill listing reached the model (the FakeProvider
/// alone cannot prove what the executor sent).
const RecordingProvider = struct {
    responses: []const provider.ChatResponse,
    idx: usize = 0,
    alloc: Allocator,
    last_system: ?[]u8 = null,
    saw_skill_body_in_messages: bool = false,

    fn init(alloc: Allocator, responses: []const provider.ChatResponse) RecordingProvider {
        return .{ .responses = responses, .alloc = alloc };
    }
    fn deinit(self: *RecordingProvider) void {
        if (self.last_system) |s| self.alloc.free(s);
    }
    fn toProvider(self: *RecordingProvider) provider.Provider {
        return .{ .ctx = self, .vtable = &vtable };
    }
    const vtable = provider.Provider.VTable{ .complete = complete, .name = name };

    fn name(_: *anyopaque) []const u8 {
        return "recording";
    }
    fn complete(ctx: *anyopaque, alloc: Allocator, req: provider.CompletionRequest) !provider.ChatResponse {
        const self: *RecordingProvider = @ptrCast(@alignCast(ctx));
        if (req.messages.len > 0 and req.messages[0].role == .system) {
            if (self.last_system) |s| self.alloc.free(s);
            self.last_system = try self.alloc.dupe(u8, req.messages[0].content);
        }
        for (req.messages) |m| {
            if (std.mem.indexOf(u8, m.content, "DEPLOY STEPS BODY") != null) {
                self.saw_skill_body_in_messages = true;
            }
        }
        const r = self.responses[self.idx];
        if (self.idx + 1 < self.responses.len) self.idx += 1;
        // Scripted responses are static slices; dupe into the request arena.
        var tcs: ?[]provider.ToolCall = null;
        if (r.message.tool_calls) |src| {
            const owned = try alloc.alloc(provider.ToolCall, src.len);
            for (src, 0..) |tc, i| {
                owned[i] = .{
                    .id = try alloc.dupe(u8, tc.id),
                    .name = try alloc.dupe(u8, tc.name),
                    .arguments_json = try alloc.dupe(u8, tc.arguments_json),
                };
            }
            tcs = owned;
        }
        return provider.ChatResponse{
            .message = .{
                .role = r.message.role,
                .content = try alloc.dupe(u8, r.message.content),
                .tool_calls = tcs,
            },
            .finish_reason = r.finish_reason,
        };
    }
};

test "skill-driven goal e2e: disk skill, prompt listing, skill tool fetch, artifact written (A3)" {
    const alloc = std.testing.allocator;

    // 1. A skill on disk in a real tmpDir (not FakeFs): the discovery half of
    //    the loop runs against the real filesystem layout.
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const tmp_abs = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(tmp_abs);
    const skill_body = "1. read the checklist\n2. write deploy-log.txt\nDEPLOY STEPS BODY";
    const skill_md = try std.fmt.allocPrint(
        alloc,
        "---\nname: deploy\ndescription: Deploy the service safely\n---\n{s}",
        .{skill_body},
    );
    defer alloc.free(skill_md);
    try tmp.dir.makePath("skills/deploy");
    try tmp.dir.writeFile(.{ .sub_path = "skills/deploy/SKILL.md", .data = skill_md });

    var realfs_impl = RealFs.init(tmp_abs);
    const disk_fs = realfs_impl.toFs();
    const roots = [_][]const u8{"skills"};
    var reg = try SkillRegistry.load(alloc, disk_fs, &roots);
    defer reg.deinit();
    try std.testing.expect(reg.find("deploy") != null);

    // 2. The listing (exactly what the composition root feeds the executor)
    //    carries the skill into the system prompt.
    const listing = try registry_mod.listingText(alloc, &reg);
    defer alloc.free(listing);
    try std.testing.expectEqualStrings("- deploy: Deploy the service safely\n", listing);

    // 3. Scripted loop: fetch the skill via the `skill` tool, then write the
    //    artifact it describes, then finish.
    const tcs_turn1 = [_]provider.ToolCall{.{ .id = "c1", .name = "skill", .arguments_json = "{\"name\":\"deploy\"}" }};
    const tcs_turn2 = [_]provider.ToolCall{.{ .id = "c2", .name = "write_file", .arguments_json = "{\"path\":\"deploy-log.txt\",\"data\":\"deployed with deploy skill\"}" }};
    const responses = [_]provider.ChatResponse{
        .{ .message = .{ .role = .assistant, .content = "", .tool_calls = &tcs_turn1 }, .finish_reason = .tool_calls },
        .{ .message = .{ .role = .assistant, .content = "", .tool_calls = &tcs_turn2 }, .finish_reason = .tool_calls },
        .{ .message = .{ .role = .assistant, .content = "deployed" } },
    };
    var rp = RecordingProvider.init(alloc, &responses);
    defer rp.deinit();

    // Goal state lives on FakeFs; goal repo + executor get the real listing.
    var fake = FakeFs.init(alloc, "/wd");
    defer fake.deinit();

    var st_impl = SkillTool.init(&reg);
    const skill_t = st_impl.toTool();
    var wt_impl = WriteTool.init(fake.toFs());
    const write_t = wt_impl.toTool();
    const tools = [_]Tool{ skill_t, write_t };
    var repo_impl = FsGoalRepository.init(fake.toFs(), ".ziki", "sess-e2e");
    const repo = repo_impl.toRepository();

    var ex = GoalExecutor{
        .alloc = alloc,
        .provider = rp.toProvider(),
        .tools = &tools,
        .repo = repo,
        .fs = fake.toFs(),
        .dir = ".ziki",
        .session_id = "sess-e2e",
        .skills_listing = listing,
    };
    var goal = try Goal.init(alloc, "deploy the service", null, "sess-e2e");
    defer goal.deinit(alloc);
    try ex.run(&goal);
    defer if (ex.report) |r| alloc.free(r);

    // 4. Assertions across the whole loop.
    try std.testing.expect(goal.status == .completed);
    // The listing reached the system prompt…
    try std.testing.expect(rp.last_system != null);
    try std.testing.expect(std.mem.indexOf(u8, rp.last_system.?, "Skills you can consult") != null);
    try std.testing.expect(std.mem.indexOf(u8, rp.last_system.?, "- deploy: Deploy the service safely") != null);
    // …the skill tool returned the verbatim body as a tool message…
    try std.testing.expect(rp.saw_skill_body_in_messages);
    // …and the executor wrote the artifact through write_file.
    const artifact = try fake.readFile(alloc, "deploy-log.txt");
    defer alloc.free(artifact);
    try std.testing.expectEqualStrings("deployed with deploy skill", artifact);
}
