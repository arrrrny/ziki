# ZIKI
### *Zig Is Kicking Idiocy. The goal-driven coding agent that doesn't eat your RAM.*

> **ZIKZAK AI MANIFESTO, internalized:**
> PROCESSES OVER PRODUCTS. PRINCIPLES OVER POPULARITY. **WTF OR NOTHING.**
> We don't *launch* — **we detonate.** Every commit must vaporize assumptions.
> This isn't development. **It's unfiltered violence against the mundane.**

Kimi is perfect. Kimi gets the job done. Kimi is also **TypeScript** — and
twenty open windows of TypeScript is ten gigabytes of RAM quietly suffocating
your machine.

**Ziki is the remedy.** Same goal-setting brain. Same tool-wielding hands. One
dependency: the compiler. No Node. No `node_modules`. No GC pauses. No 400 MB of
runtime just to ask a model which file to open next.

A single static binary. **Sub-gigabyte footprint across twenty sessions.** We're
not optimizing — we're deleting the disease.

## WHY ZIG (AND WHY YOU SHOULD CARE)

This isn't a language choice. It's a statement.

- **You allocate, or you don't. There is no third option.** Every byte has a
  name and an owner. The allocator is an interface, not a mystery. When the goal
  loop spins through fifty turns, memory doesn't creep — it returns.
- **`comptime` does the work your build scripts used to.** Provider presets,
  tool schemas, JSON shapes — resolved at compile time, gone at runtime.
- **No runtime. No VM. No "event loop" pretending to be the OS.** `zig build`
  emits a binary that talks to the kernel directly. Twenty windows are twenty
  processes, not twenty tube factories of closures.
- **One client, six providers, zero branching.** `cliproxy`, `opencode`, `kilo`,
  `z.ai`, `kimi`, `openai_custom` — all the same OpenAI-shaped boundary. Add a
  provider, you add a config line, not a code path. That's the Open/Closed
  Principle with a chainsaw.

## WHAT IT DOES

```
/goal "write a file and run the tests" --provider cliproxy
```

Ziki opens a session, calls the model, the model calls tools, Ziki executes
them on your filesystem, the loop runs until the goal is *done* — not until the
context window vomits. State persists to disk. Resume survives a crash.

- **Goal setting** — the feature we refused to compromise. Define an objective
  and a completion criterion; Ziki doesn't stop guessing, it stops when the
  criterion is met.
- **Tool layer** — read, write, edit, search, exec. Each is a boundary, not a
  helper function. Swap the filesystem, swap the transport, the logic doesn't
  flinch.
- **Provider boundary** — one interface, six presets. Bring your own endpoint.
- **Low-footprint runtime** — this is the whole point. We measured. It's rude.

## THE GYM (GROW YOUR MUSCLES)

A test proves the software works. **A GYM proves you can wield it.**

Ziki ships lean and mean. Before you point it at real work, do the reps: run a
goal, watch it complete, read the state file, understand the loop. By the time
you're done, Ziki isn't foreign — it's meat on your bones.

**WTF OR NOTHING.** If a feature doesn't make you say *wtf, this is clean*, it
doesn't ship.

## BUILD

```bash
zig build
zig build test      # 33 tests. all green. no exceptions.
./zig-out/bin/ziki /goal "your objective" --provider cliproxy
```

Config lives at `~/.config/ziki/config.json`:

```json
{
  "active_provider": "cliproxy",
  "endpoint": "http://localhost:8317/v1",
  "model": "mimo-v2.5",
  "api_key": "your-key"
}
```

## PRINCIPLES (NON-NEGOTIABLE)

S.O.L.I.D., no exceptions. Dependency inversion — write to the interface.
Closed for modification, open for extension. D.R.Y. **Write the test first.**
T.D.D. is not a methodology here; it's the only way the code enters the repo.

## LICENSE

MIT. Take it. Wield it.

---

**WE BUILD ZIKI WITH YOU, NOT FOR YOU. DETONATE.**
