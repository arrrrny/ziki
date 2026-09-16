# Tasks: [Lane F] Zig 0.16 std.Io migration
**Branch**: `018-zig-0.16-migration` | **Spec**: `spec.md` | **Plan**: `plan.md`

- [x] **T1** `src/compat.zig`: Io + environ singleton (`init(env)` from main; `std.testing.io` in tests; `getEnvOwned`/`getenv`).
- [x] **T2** Migrate the foundation: fs.zig (Io.Dir, realpath via readLink loop), goal.zig (io.now clock), dispatcher (array_hash_map), config.zig.
- [x] **T3** Migrate agents/tools/skills: state.zig Sink, executor, herdr, bash (Child 0.16), skill/*, search, transports (Io.net, http.Client, HostName, Unix sockets).
- [x] **T4** Migrate main.zig (Env struct entry point) + shell + test files.
- [x] **T5** `zig fmt` the tree; suite green under 0.16.0.
- [x] **T6** CI: 0.16.0 required gate + `zig fmt --check`; retire 0.15.2 job. Update tdd-profile.md + README toolchain notes.
