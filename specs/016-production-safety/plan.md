# Implementation Plan: [Lane D] Production safety
**Branch**: `016-production-safety` | **Spec**: `spec.md` | **Issue**: #19

## Summary
Three additions: (1) intent-resolving push gate, (2) already-applied pre-check, (3) a report-completeness integration test.

## Technical Decisions
- **D1 — Gate as pure recursive segment analysis** (`bash.zig`): a quote-aware scanner splits the command on top-level `&&`/`||`/`;`/`|`; each segment either matches a shell wrapper (`sh|bash|zsh|dash -c <script>` → recurse on the de-quoted script, depth-capped, deeper nesting fails closed) or is analyzed as a `git` invocation: skip global options that consume values (`-C`, `-c`), find the subcommand; `push` is gated unless `--dry-run`; an UNKNOWN subcommand is gated (a configured alias could expand to a push — fail closed); a fixed allow-list of known read-only/local subcommands stays allowed. The public `isUnauthorizedGitPush` signature is unchanged.
- **D2 — Pre-check placement** (`executor.zig`): in `runWithHistory`, after conversation seeding and the `working` announcement, only for fresh goals (`history.len == 0`) with a criterion: one `verify()` call; on YES → `finish(.completed, "already done: criterion satisfied before starting", …)` + skip note. Resume runs skip the pre-check (their transcript already reflects progress).
- **D3 — Completeness by integration test**: tmpDir + real git (house style from `revertIncidental`), RealFs, scripted WriteTool (untracked intentional file) + BashTool `run_command` (incidental drift) + pre-existing untracked user file; assert the exact report sections and that the user file survives untouched.
