# Contract: Tool Interface (`tool/tool.zig`)

Coding tools expose a single narrow method so the executor depends only on what
it uses (ISP, Principle I.4). This mirrors Kimi tool parity (FR-007).

## Interface

```
Tool = struct {
    ctx: *anyopaque,
    vtable: *const VTable,
};
VTable = struct {
    execute: fn (ctx: *anyopaque, alloc: Allocator, args_json: []const u8) anyerror!ToolResult,
    name: fn (ctx: *anyopaque) []const u8,
    schema: fn (ctx: *anyopaque) ToolSpec,   // name + description + parameters JSON schema
};
ToolResult = struct { ok: bool, output: []const u8, error_message: ?[]const u8 };
```

## Implementations (FR-007)

- `ReadTool` (`tool/read.zig`): read a file's contents (path in `args_json`).
- `EditTool` (`tool/edit.zig`): exact-match replace in a file (old/new/path).
- `SearchTool` (`tool/search.zig`): regex/string search over files (ripgrep-like
  subset via std). Returns matching paths + lines.
- `BashTool` (`tool/bash.zig`): run a shell command, capture stdout/stderr/exit.

All tools access the filesystem ONLY through the injected `fs.Fs` interface
(`fs/fs.zig`), so they are testable with `FakeFs` (DIP, Principle II). Paths are
resolved relative to the session working directory; symlink escapes are rejected.

## Errors

A tool returns `ToolResult{ .ok = false, .error_message = ... }` on failure
(file not found, bad args, non-zero command exit). The executor feeds the error
back to the model as a `tool` role message; the tool itself MUST NOT crash the
process. Malformed `args_json` -> `ok=false` with a clear message (never a
panic).
