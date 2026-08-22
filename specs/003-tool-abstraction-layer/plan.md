# Plan: Tool Abstraction Layer

**Feature**: `003-tool-abstraction-layer`
**Status**: Implemented and verified; merged to `MASTER` via PR #1. This plan
documents the design and the verification evidence for sign-off.

## Goal

Expose four agent capabilities — read a file, edit a file, search contents by
pattern, and execute a shell command — behind a single injectable `Tool`
interface so the executor depends only on the interface (Dependency
Inversion, per the constitution). Every tool returns a structured result and
must never crash or unwind the process on error.

## Architecture & Key Decisions

- **Injectable interface (DIP)**: `Tool` is a vtable struct
  (`ctx: *anyopaque` + `VTable{ execute, schema, name }`). Concrete tools are
  constructed with `init(fs)` and exposed through `toTool()`. The executor holds
  a `[5]Tool` array and never references a concrete tool type (spec 003, FR-002).
- **Narrow interface (ISP)**: the executor calls only `Tool.execute(alloc,
  args_json)`. Each tool parses its own JSON arguments, so the surface stays
  minimal and stable.
- **Structured results, never exceptions**: `ToolResult { ok, output,
  error_message }`. Tools communicate success/failure through this object; the
  executor branches on `ok`. A failed tool is a normal result, not a panic
  (FR-003).
- **Filesystem behind an interface**: tools receive an `Fs` interface
  (`src/fs/fs.zig`) so they can run against a real working directory or a fake
  `Fs` in tests without code changes (FR-009, FR-010).
- **Bounded command execution**: `BashTool` captures exit status + stdout/stderr
  and survives non-zero exits; output is capped so a noisy command cannot blow
  the heap (FR-008).

## Files

| File | Responsibility |
|------|----------------|
| `src/tool/tool.zig` | `Tool` vtable interface + `ToolResult` |
| `src/tool/read.zig` | ReadTool — read a file's contents |
| `src/tool/edit.zig` | EditTool — create/replace a region |
| `src/tool/write.zig` | WriteTool — write full content |
| `src/tool/search.zig` | SearchTool — pattern match across files |
| `src/tool/bash.zig` | BashTool — bounded shell execution |
| `src/fs/fs.zig` | `Fs` interface + `RealFs` |
| per-tool `*_test` blocks | Independent tool tests (temp dir / fake) |

## Verification Evidence

- `zig build test` → 23/23 pass on a clean compile. The tool set contributes
  five independent tests: `ReadTool reads via Fs`, `EditTool replaces exactly
  once`, `SearchTool finds matching lines`, `WriteTool writes via Fs`,
  `BashTool runs a command`.
- The executor test (`GoalExecutor drives a goal to completion`) drives the
  tools through the `Fs` interface with `FakeFs` + `FakeProvider`, proving no
  tool-specific logic lives above the interface (SC-003, SC-005).
- Error paths (missing file, unapplicable edit, no match, non-zero exit) return
  `ToolResult{ .ok = false, .error_message = ... }` without crashing.

## Notes

Behavior is fully specified in `spec.md`; no separate research/data-model/
contracts artifacts are required for this layer. The four capabilities are a
prerequisite for the autonomous goal execution feature (spec 006).
