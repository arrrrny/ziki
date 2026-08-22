const std = @import("std");

/// Parsed result of one input line. The dispatcher routes by `command`; the
/// handler interprets `args` (command-specific parsing stays in the handler,
/// per the constitution's Dependency Inversion mandate — SC-005).
pub const Intent = struct {
    /// Command name after `/` (e.g. "goal"). Empty (`""`) for non-slash lines.
    command: []const u8,
    /// Raw, trimmed remainder after the command name. May be empty.
    args: []const u8,
    /// The original, unmodified input line.
    raw: []const u8,
};

/// What a handler returns after acting on an intent.
pub const Result = struct {
    /// Text to print back to the output sink. Allocated by the handler via the
    /// allocator passed to `handle`; the REPL frees it after writing.
    output: []const u8,
    /// When true, the REPL loop terminates after printing.
    exit: bool = false,
};
