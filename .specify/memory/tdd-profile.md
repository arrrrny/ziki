---
detected_at: 9376b03 # short SHA the profile was detected against
ecosystems: [zig] # one entry per detected stack
default: zig # which one the loop uses when a path is ambiguous
stacks:
  zig:
    cwd: . # working directory every command below runs in
    runner: zig-test # Zig's built-in test framework (no third-party runner)
    # --test-filter matches NOTHING in this Zig 0.15.2 build: it reports
    # "All 0 tests passed" for every input, including the exact qualified
    # name `src.tool.bash.test.BashTool runs a command`. That is a silent
    # false-green, so it is unsafe. The loop must run the whole suite instead.
    single: null
    # `zig test <file>` fails for every module that uses `../` relative imports
    # (e.g. `@import("../fs/fs.zig")`) with "import of file outside module path".
    # There is no file that runs standalone cleanly, so the loop runs the suite.
    file: null
    suite: zig build test # authoritative suite command; equivalent: zig test tests.zig
    watch: null # no built-in watch mode for `zig test`
    coverage: kcov --include-pattern=src/ <out> .zig-cache/o/<hash>/test # full suite only; single:null so no per-test coverage; kcov 43 installed via brew
    mutation: null # no Zig mutation tool installed (cargo-mutants-style tools absent)
    property: null # no property-based testing library
    acceptance: null # no dedicated E2E/acceptance runner; CLI covered via executor integration tests
    contract: null # no contract-test tool
    approval: null # no approval/snapshot tool
    test_glob: "src/**/*.zig" # tests live inline in source files
    exemplar: # one per test kind the stack can run
      unit: src/tool/bash.zig
      integration: src/agent/executor.zig
    helpers: # test utilities a new test reuses instead of hand-rolling
      - src/fs/fs.zig # FakeFs: in-memory fake of the Fs interface (FakeFs.init(alloc, cwd))
      - src/provider/fake.zig # FakeProvider / FlakyProvider: scripted fake of the Provider interface
      - std.testing # expect*, expectEqual*, expectError, allocator, tmpDir
verified: [suite, coverage] # suite + kcov coverage run executed successfully
suite_baseline: green # green | red, at detection time
suite_seconds: 41 # observed wall time of the full suite (full compile + run)
---

# TDD Stack Profile

## Conventions to match

- Tests are top-level `test "name" {}` blocks embedded in the source `.zig`
  files (Zig's built-in framework). There is no separate test directory or runner
  config. `tests.zig` is the aggregator: it `@import`s every module so
  `zig build test` collects and runs all of them.
- Assertions use `std.testing.expect`, `expectEqual`, `expectEqualStrings`,
  `expectError`. Use `std.testing.allocator`; use `std.testing.tmpDir(.{})` for
  scratch files (see `src/agent/executor.zig` `revertIncidental` test).
- Doubles are hand-written fakes implementing the project's interfaces, reached
  only through dependency injection (Constitution Principle II):
  - `src/fs/fs.zig` → `FakeFs`, the in-memory `Fs`: `FakeFs.init(allocator, cwd)`.
  - `src/provider/fake.zig` → `FakeProvider` (scripted: `FakeProvider.init(&responses)`
    then `.toProvider()`) and `FlakyProvider` (fails first N times then succeeds).
  - Tests must never touch `std.fs`, the network, or a real provider; go through
    the injected fakes.
- Exemplars to imitate:
  - Unit: `src/tool/bash.zig` — `test "BashTool runs a command"` (line 193)
    builds a `FakeFs`, exercises a tool, and asserts with `std.testing`.
  - Integration: `src/agent/executor.zig` —
    `test "GoalExecutor drives a goal to completion (FakeProvider + FakeFs)"`
    (line 404) drives the real `GoalExecutor` end-to-end with `FakeProvider` +
    `FakeFs`, then asserts on the resulting goal/report.
- A new behavior's test lives in the same file as the code it covers, named
  `test "descriptive behavior"`. It reaches the suite only if its module is
  `@import`ed in `tests.zig` AND referenced (e.g. `_ = mod;`) inside the
  aggregator's `test "aggregator loads all modules"` block — see the gap below.

## Notes and constraints

- `single` and `file` are UNAVAILABLE (see frontmatter). The loop MUST run the
  full suite `zig build test` for every red/green check. `zig test tests.zig` is
  an equivalent entry point.
- Suite wall time is ~41s (full compile + run). A per-cycle full run is viable
  but slow (budget ~1 minute per check). There is no incremental/fast subset.
- Coverage: available via `kcov` (installed v43 via `brew install kcov`, verified
  on macOS 0.15.2). Verified command:
  `kcov --include-pattern=src/ <out-dir> .zig-cache/o/<hash>/test` runs the full
  suite and emits HTML + `coverage.json`. Get the binary hash with
  `zig build test` then `ls -t .zig-cache/o/*/test | head -1`. Do NOT pass
  `--listen=-`: that is `zig build`'s server mode and aborts standalone. Observed
  baseline (2026-08-26): **86.92%** overall (1256/1445 lines); the proxy transport
  `src/provider/transport.zig` is the lowest at **66.34%** (manual CONNECT+TLS and
  error branches). Single-test coverage is impossible (`single: null`), so the loop
  covers the whole suite. The audit no longer needs the trace-only fallback.
- Mutation testing: none. No Zig mutation tool is installed. The audit uses
  deliberate mutants instead (break the implementation in one small way, confirm
  a test fails, restore exactly).
- Property-based testing: none. Express invariants as boundary example tests and
  note in the test list that the invariant is sampled, not proven.
- Watch mode: none built-in. A human can approximate with `entr`/`watchexec`,
  but that is not a verified command and the loop will not rely on it.
- Acceptance / E2E runner: none dedicated. CLI-level behavior is exercised only
  through the executor integration tests; `src/main.zig` has no tests. No
  contract or approval/snapshot tool exists.
- **GAP — `src/shell/shell_test.zig` is NOT collected by the suite.** Its 7 tests
  (parsing, dispatch, REPL) do not run under `zig build test`: the aggregator's
  `test "aggregator loads all modules"` block references every other module via
  `_ = mod;` but omits `shell_test`. Running the file standalone fails to
  compile — `Capture.init` calls `std.ArrayList(u8).initCapacity(a, 0)`, which in
  Zig 0.15 returns an error union and must be `try`-wrapped (verified: exit 1).
  These tests are currently dead and broken. Work in the shell package needs this
  fixed first; the loop cannot rely on them until then.
- `memory-harness.sh` is an operational memory-budget harness for the built REPL
  binary, not part of the test suite. It does not gate merges and is out of scope
  for TDD.
