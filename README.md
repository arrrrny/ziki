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
- **Skills** — drop a `SKILL.md` in a skills directory and the agent can use
  it, exactly like any coding editor. Just like kimi.
- **Low-footprint runtime** — this is the whole point. We measured. It's rude.

## SKILLS

A skill is a `SKILL.md` file — YAML frontmatter (`name`, `description`) and a
markdown body of instructions:

```markdown
---
name: code-review
description: Review code for SOLID violations
---
## Steps
1. Read the diff
2. Check every principle
```

Ziki discovers skills from three roots, highest precedence first:

| Root | Lives | Committed? |
|------|-------|------------|
| `.ziki/skills/` | this project, this machine | no (local overrides) |
| `.kimi-code/skills/` | this project, the team | yes (kimi-code compatible) |
| `~/.config/ziki/skills/` | every project, you | your call |

Same name in two roots? The higher root wins. Malformed skill? Skipped with a
warning — it never takes the agent down. Zero skills? `/goal` behaves exactly
as without them.

During a goal, every skill's name and description is in the agent's context,
and the model fetches a skill's full instructions on demand through the
`skill` tool. Interactive users inspect the same registry:

```
/skill list            # name, description, source — plus load warnings
/skill show <name>     # the full instructions, verbatim
```

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
zig build test      # 65 tests. all green. no exceptions.
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

## HERDR STATE SYNC

When Ziki runs inside a [Herdr](https://github.com/arrrrny/herdr) pane, it publishes
its live agent state so Forklift and the Herdr sidebar can coordinate panes without
transcript scraping (spec `011-herdr-ziki-state-sync`, FR-001…FR-008).

Two optional environment variables drive it:

| Variable | Default | Effect |
| --- | --- | --- |
| `HERDR_PANE_ID` | unset | When set, Ziki pushes `working`/`blocked`/`idle` to Herdr's agent-state API (`${HERDR_API_URL}/api/v1/pane/report/agent`). When unset, Ziki degrades to **screen-only** mode: it still emits the `[ziki-state: <state>]` marker and the `\x1b]2;ziki:<state>\x07` OSC title to stdout, so Herdr can classify the pane without the push path — no crash either way. |
| `HERDR_API_URL` | `http://localhost:7878` | Base URL of the Herdr instance to report state to. |

State is pushed authoritatively: the pushed `state` always matches the on-screen
marker, and `seq` is strictly increasing so a stale report can never win. On a clean
exit Ziki always pushes a terminal `idle`. (A pane that dies without a terminal report
is resolved to `unknown` by Herdr's own detection window — a cross-repo concern.)

## PRINCIPLES (NON-NEGOTIABLE)

S.O.L.I.D., no exceptions. Dependency inversion — write to the interface.
Closed for modification, open for extension. D.R.Y. **Write the test first.**
T.D.D. is not a methodology here; it's the only way the code enters the repo.

## LICENSE

MIT. Take it. Wield it.

---

**WE BUILD ZIKI WITH YOU, NOT FOR YOU. DETONATE.**
