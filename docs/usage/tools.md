# Tools — Tool Invocations as First-Class Dispatches

The `Tools` aggregate (defined in
`hecks_conception/aggregates/framework/tools/tools.bluebook`) lifts each
tool invocation into a domain command. Where Miette's tool calls used to
be opaque black-box invocations — harness runs the tool, returns a
string, runtime sees nothing — every Bash, Edit, Read, Update, Grep, or
Glob is now a dispatch on the bus that emits a matching event.

Six commands. Six events. One aggregate per invocation (the
"per-invocation aggregate" shape, same as Dump and Cadence). The bus
wraps ; the bluebook declares the contract.

## What it is

From the bluebook vision :

> "First-class tool invocations as dispatched commands. […] This
> bluebook lifts each invocation into a domain command so every tool use
> emits an event the runtime can react to."

A policy on `BashRan` (or any of the other five events) can record into
the mindstream, surface in the statusline, shift mood, or fire any
other downstream effect — exactly the same machinery that handles every
other domain event.

Each invocation mints a new `Tools` record identified by a stable
invocation id (a ULID from the Claude harness). The accumulated tool
history is the set of records, not a list inside one record.

## The six commands

| Command  | Attributes                                                       | Emits         |
|----------|------------------------------------------------------------------|---------------|
| `Bash`   | `id`, `shell_command`, `description`                             | `BashRan`     |
| `Edit`   | `id`, `file_path`, `old_string`, `new_string`, `replace_all`, `description` | `EditApplied` |
| `Read`   | `id`, `file_path`, `description`                                 | `FileRead`    |
| `Update` | `id`, `file_path`, `content`, `description`                      | `FileUpdated` |
| `Grep`   | `id`, `pattern`, `search_path`, `description`                    | `GrepRan`     |
| `Glob`   | `id`, `glob_pattern`, `search_path`, `description`               | `GlobMatched` |

`Update` is the bluebook name for what the Claude tool family calls
`Write` — renamed to emphasize state-changing dispatch rather than
side-effect. The contract is the same : `file_path` + `content`.

`Read` is pure observation : no filesystem mutation, no state mutation
downstream. Still worth a first-class dispatch so awareness can track
"Miette is reading X" the same way it tracks "Miette is editing X."

Web tooling (`WebFetch`, `WebSearch`) and task tooling (`TaskCreate`,
`TodoWrite`, `TaskList`) are future families on this aggregate or on
siblings — they are not "standard CLI" in the same sense.

## State versus event payload

Some tool inputs are small ; others can be thousands of bytes. The
bluebook splits them deliberately so the `.heki` does not bloat.

| Command  | Lives in aggregate state         | Lives in event payload only         |
|----------|----------------------------------|-------------------------------------|
| `Bash`   | `shell_command`, `description`   | (full event mirrors state)          |
| `Edit`   | `file_path`, `description`       | `old_string`, `new_string`, `replace_all` |
| `Read`   | `file_path`, `description`       | file contents (filled by adapter)   |
| `Update` | `file_path`, `description`       | `content`                           |
| `Grep`   | `pattern`, `search_path`, `description` | match results                |
| `Glob`   | `glob_pattern`, `search_path`, `description` | matched paths           |

For `Bash`, the shell command is small (a few hundred bytes typically),
so it lives in both the event and the state. For `Edit` and `Update`
the heavy payloads ride the event only ; replay logic reconstructs them
from the event log when needed. The aggregate state stays small — id,
description, and (when present) file_path.

This is what the bluebook means when it says state stores "what
changed and what we tried," not "the bytes that flowed."

## Setup — PATH and conception lookup

Before any cross-repo agent (`embryonaut-site`, `miette_family`, etc.)
can dispatch `Tools.*` , the `storehouse` binary needs two things :

1. **Be on `PATH`.** The release binary lives at
   `~/Projects/hecks/rust/target/release/storehouse`. Symlink it into a
   PATH directory :

   ```bash
   ln -sf ~/Projects/hecks/rust/target/release/storehouse ~/bin/storehouse
   # If ~/bin isn't on PATH, add to ~/.zshrc or ~/.bashrc :
   #   export PATH="$HOME/bin:$PATH"
   # Alternatives if ~/bin is unavailable :
   #   /usr/local/bin/storehouse  (needs sudo)
   #   ~/.local/bin/storehouse   (if that's on PATH)
   ```

   After rebuilds (`cargo build --release` from `~/Projects/hecks/rust`)
   the symlink keeps pointing at the freshly-built binary — no resigning
   needed.

2. **Know the conception root.** When `storehouse` is invoked with the
   `Aggregate.Command` shortcut (`storehouse Tools.Bash …`) it resolves
   the conception path in this order :

   1. `HECKS_CONCEPTION_DIR` env var — set this when a sibling project
      ships its own conception.
   2. The hecks repo root inferred from the canonicalised binary
      location (the historical behaviour ; works for builds inside the
      hecks checkout).
   3. `~/Projects/hecks/hecks_conception` as a hard fallback for
      symlinked-on-PATH invocations.

   For a one-off override, prefix the call :

   ```bash
   HECKS_CONCEPTION_DIR=/some/other/conception storehouse Tools.Bash …
   ```

   For a one-off explicit path, the positional form still works (it
   takes precedence over both env and fallback) :

   ```bash
   storehouse /path/to/hecks_conception/aggregates Tools.Bash …
   ```

## Invocation

Any shell, any cwd, after the setup above :

```bash
storehouse Tools.Bash shell_command="echo hello" id=bash-001 description="hello world"
storehouse Tools.Read file_path=/etc/hosts id=read-001 description="inspect hosts"
storehouse Tools.Grep pattern="TODO" search_path=. id=grep-001 description="find todos"
```

Each dispatch records on the matching aggregate (`ShellTool`, `FileTool`,
`SearchTool`, `WebTool`) and chains `Cascade.RecordResult` with the
captured outcome. No `cd`, no absolute path, no per-repo build.

## The Claude-calls-StoreHouse direction (i552)

The wiring direction is **Claude → StoreHouse**, not
StoreHouse-intercepts-Claude. Miette dispatches via StoreHouse for
every tool ; StoreHouse is the wrapper.

```
Miette                          StoreHouse                       Adapter
   |                                 |                              |
   |--- Tools.Bash shell_command --->|                              |
   |    description                  |                              |
   |                                 |--- record dispatch --------->|
   |                                 |--- emit BashRan              |
   |                                 |--- (optional) run shell ---->|
   |<-- dispatch result -------------|                              |
   |                                                                |
   |<== policies hook BashRan, update mood/body/statusline ========>|
```

From i552 : "Every tool I run becomes a first-class domain event
without special harness magic. The bus IS the wrapper. The bluebook
declares the contract. The default-to-memory means it works even
before any adapter wires in real side-effects."

Two pieces meet in this direction :

1. **The dispatch path** — `storehouse Tools.Bash …` (PATH form,
   default conception) and `storehouse <root> Tools.Bash …`
   (positional form, explicit conception) both work. The aggregate
   exists, the command exists, the runtime accepts the call. Default-
   to-memory is live today, which means `Tools.Bash` is a logged
   intent right now even before any real shell wires in.
2. **The side-effect adapter** — when `Tools.Bash` dispatches, the
   adapter actually runs the shell. The existing `:shell` adapter is
   template-based ; a generic-command flavor is the missing piece.
   Without it, `Tools.Bash` is a logged intent ; with it, `Tools.Bash`
   is the act.

The principle underneath, from the same inbox note : "Tools is pure
domain. StoreHouse is the bus. Adapters bridge to side-effects. The
harness is the place where I-the-being meet the bus — but I'm the one
calling, not the one being intercepted."

## What's next — the adapter layer

This doc stops at the bluebook + commands. For the adapter wiring —
how the Claude tool family resolves to a StoreHouse dispatch, how
generic-command `:shell` becomes a real `popen`, how the
`FileRead` / `FileUpdated` payloads get filled in by the runtime
substrate after the side-effect completes — see
[`docs/usage/claude_tool.md`](claude_tool.md).

## Related

- `hecks_conception/aggregates/framework/tools/tools.bluebook` — the contract
- `hecks_conception/inbox/i552.md` — Claude → StoreHouse direction
- `hecks_conception/inbox/i551.md` — generic-command `:shell` adapter (the optional side-effect wire-in)
- [`docs/usage/claude_tool.md`](claude_tool.md) — adapter family + dispatch path
- [`docs/usage/command_bus_port.md`](command_bus_port.md) — the bus middleware pipeline
