const std = @import("std");
const Allocator = std.mem.Allocator;

/// One loaded skill (FR-001): kimi-code convention `SKILL.md` — `---`-delimited
/// frontmatter carrying at least `name` and `description`, followed by a
/// markdown body. Immutable after parse; every field is owned by the allocator
/// passed to `parse` and released by `deinit`.
pub const Skill = struct {
    /// Authoritative skill identifier (frontmatter wins over directory name).
    name: []const u8,
    /// One-line summary shown in listings and the agent system prompt.
    description: []const u8,
    /// Verbatim markdown body after the closing `---` line.
    body: []const u8,
    /// Root the skill was loaded from (listing/diagnostics only).
    source: []const u8,

    pub fn deinit(self: Skill, alloc: Allocator) void {
        alloc.free(self.name);
        alloc.free(self.description);
        alloc.free(self.body);
        alloc.free(self.source);
    }
};

/// Typed parse failures so the registry can warn precisely (FR-003).
pub const ParseError = error{
    NoFrontmatter,
    UnterminatedFrontmatter,
    MissingName,
    MissingDescription,
    OutOfMemory,
};

/// Parse `SKILL.md` content into a `Skill`. Pure function: bytes in, skill
/// out — no filesystem, no globals (testable in isolation). `source` is only
/// recorded, never inspected. Only simple scalar `key: value` frontmatter
/// fields are understood; unknown keys are ignored (spec Assumptions).
pub fn parse(alloc: Allocator, source: []const u8, raw: []const u8) ParseError!Skill {
    // The file must open with a `---` line (tolerating \r\n).
    if (!std.mem.startsWith(u8, raw, "---")) return error.NoFrontmatter;
    var rest = raw[3..];
    if (rest.len > 0 and rest[0] == '\n') {
        rest = rest[1..];
    } else if (rest.len >= 2 and rest[0] == '\r' and rest[1] == '\n') {
        rest = rest[2..];
    } else {
        // "---" immediately followed by something else: not a frontmatter fence.
        return error.NoFrontmatter;
    }

    var name: ?[]const u8 = null;
    var description: ?[]const u8 = null;
    var body_start: ?usize = null;

    var pos: usize = 0;
    while (pos <= rest.len) {
        if (pos == rest.len) break;
        const nl = std.mem.indexOfScalarPos(u8, rest, pos, '\n') orelse rest.len;
        var line = rest[pos..nl];
        line = std.mem.trim(u8, line, " \t\r");
        if (std.mem.eql(u8, line, "---")) {
            body_start = if (nl < rest.len) nl + 1 else rest.len;
            break;
        }
        if (std.mem.indexOfScalar(u8, line, ':')) |ci| {
            const key = std.mem.trim(u8, line[0..ci], " \t");
            const value = stripQuotes(std.mem.trim(u8, line[ci + 1 ..], " \t"));
            if (std.mem.eql(u8, key, "name")) {
                name = value;
            } else if (std.mem.eql(u8, key, "description")) {
                description = value;
            }
            // Unknown keys are ignored by design.
        }
        if (nl == rest.len) break;
        pos = nl + 1;
    }
    if (body_start == null) return error.UnterminatedFrontmatter;

    const n = name orelse return error.MissingName;
    if (n.len == 0) return error.MissingName;
    const d = description orelse return error.MissingDescription;
    if (d.len == 0) return error.MissingDescription;

    // Body: verbatim after the closing fence's newline, minus one leading
    // blank line separator.
    var body = rest[body_start.?..];
    if (body.len >= 2 and body[0] == '\r' and body[1] == '\n') {
        body = body[2..];
    } else if (body.len > 0 and body[0] == '\n') {
        body = body[1..];
    }

    return Skill{
        .name = try alloc.dupe(u8, n),
        .description = try alloc.dupe(u8, d),
        .body = try alloc.dupe(u8, body),
        .source = try alloc.dupe(u8, source),
    };
}

/// Strip one matching pair of surrounding quotes (single or double).
fn stripQuotes(v: []const u8) []const u8 {
    if (v.len >= 2) {
        const first = v[0];
        const last = v[v.len - 1];
        if ((first == '"' and last == '"') or (first == '\'' and last == '\'')) {
            return v[1 .. v.len - 1];
        }
    }
    return v;
}

// ---------------------------------------------------------------------------
// Tests (constitution Principle V: tests first, no exceptions).
// ---------------------------------------------------------------------------

test "parse valid SKILL.md with name, description and body" {
    const alloc = std.testing.allocator;
    const raw =
        \\---
        \\name: code-review
        \\description: Review code for SOLID violations
        \\---
        \\## Steps
        \\
        \\1. Read the diff
        \\2. Check the constitution
    ;
    const s = try parse(alloc, ".ziki/skills", raw);
    defer s.deinit(alloc);
    try std.testing.expectEqualStrings("code-review", s.name);
    try std.testing.expectEqualStrings("Review code for SOLID violations", s.description);
    try std.testing.expectEqualStrings("## Steps\n\n1. Read the diff\n2. Check the constitution", s.body);
    try std.testing.expectEqualStrings(".ziki/skills", s.source);
}

test "parse strips surrounding quotes from frontmatter values" {
    const alloc = std.testing.allocator;
    const raw =
        \\---
        \\name:   "quoted skill"
        \\description: 'single quoted'
        \\---
        \\body text
    ;
    const s = try parse(alloc, "src", raw);
    defer s.deinit(alloc);
    try std.testing.expectEqualStrings("quoted skill", s.name);
    try std.testing.expectEqualStrings("single quoted", s.description);
}

test "parse tolerates CRLF line endings" {
    const alloc = std.testing.allocator;
    const raw = "---\r\nname: win\r\ndescription: crlf skill\r\n---\r\n\r\nbody";
    const s = try parse(alloc, "src", raw);
    defer s.deinit(alloc);
    try std.testing.expectEqualStrings("win", s.name);
    try std.testing.expectEqualStrings("crlf skill", s.description);
    try std.testing.expectEqualStrings("body", s.body);
}

test "parse ignores unknown frontmatter keys" {
    const alloc = std.testing.allocator;
    const raw =
        \\---
        \\name: x
        \\description: y
        \\compatibility: whatever
        \\metadata: ignored
        \\---
        \\b
    ;
    const s = try parse(alloc, "src", raw);
    defer s.deinit(alloc);
    try std.testing.expectEqualStrings("x", s.name);
    try std.testing.expectEqualStrings("y", s.description);
}

test "parse rejects missing frontmatter" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.NoFrontmatter, parse(alloc, "src", "just markdown, no fence"));
    try std.testing.expectError(error.NoFrontmatter, parse(alloc, "src", ""));
    try std.testing.expectError(error.NoFrontmatter, parse(alloc, "src", "----\nname: x\n---\n"));
}

test "parse rejects unterminated frontmatter" {
    const alloc = std.testing.allocator;
    const raw =
        \\---
        \\name: x
        \\description: y
        \\body without closing fence
    ;
    try std.testing.expectError(error.UnterminatedFrontmatter, parse(alloc, "src", raw));
}

test "parse rejects missing or empty name" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.MissingName, parse(alloc, "src", "---\ndescription: d\n---\nbody"));
    try std.testing.expectError(error.MissingName, parse(alloc, "src", "---\nname:\ndescription: d\n---\nbody"));
    try std.testing.expectError(error.MissingName, parse(alloc, "src", "---\nname: \"\"\ndescription: d\n---\nbody"));
}

test "parse rejects missing or empty description" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.MissingDescription, parse(alloc, "src", "---\nname: n\n---\nbody"));
    try std.testing.expectError(error.MissingDescription, parse(alloc, "src", "---\nname: n\ndescription:\n---\nbody"));
}

test "parse allows empty body (frontmatter-only skill)" {
    const alloc = std.testing.allocator;
    const s = try parse(alloc, "src", "---\nname: n\ndescription: d\n---\n");
    defer s.deinit(alloc);
    try std.testing.expectEqualStrings("", s.body);
    try std.testing.expectEqualStrings("n", s.name);
}

test "parse takes the last value when a key repeats" {
    const alloc = std.testing.allocator;
    const raw =
        \\---
        \\name: first
        \\name: second
        \\description: d
        \\---
        \\b
    ;
    const s = try parse(alloc, "src", raw);
    defer s.deinit(alloc);
    try std.testing.expectEqualStrings("second", s.name);
}
