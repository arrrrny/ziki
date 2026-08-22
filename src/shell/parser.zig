const std = @import("std");
const Intent = @import("intent.zig").Intent;

/// Parse one raw input line into an `Intent`. Pure, no side effects.
///
/// - empty/whitespace-only line  -> `null` (no intent, no dispatch)
/// - line without leading `/`    -> `Intent{ command = "", args = text }`
///                                  (routed to the default handler, not a command)
/// - `/name rest`                -> `Intent{ command = "name", args = "rest" }`
/// - `/` or `/ ` (no name)       -> `error.MalformedCommand`
pub fn parseLine(line: []const u8) !?Intent {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0) return null;

    if (trimmed[0] != '/') {
        return Intent{ .command = "", .args = trimmed, .raw = line };
    }

    const rest = trimmed[1..];
    if (rest.len == 0) return error.MalformedCommand;

    var i: usize = 0;
    while (i < rest.len and !std.ascii.isWhitespace(rest[i])) : (i += 1) {}
    if (i == 0) return error.MalformedCommand;

    const command = rest[0..i];
    const args = if (i < rest.len) std.mem.trim(u8, rest[i..], " \t\r\n") else "";
    return Intent{ .command = command, .args = args, .raw = line };
}
