# Tools — Tool Invocations as First-Class Dispatches

The Tools bluebook (defined in
`hecks_conception/aggregates/framework/tools/tools.bluebook`) lifts each
tool invocation into a domain command. Where Miette's tool calls used to
be opaque black-box invocations — harness runs the tool, returns a
string, runtime sees nothing — every Bash, Edit, Read, Update, Grep,
Glob, WebFetch, or WebSearch is now a dispatch on the bus that emits a
matching event.

## The five category aggregates (2026-05-12 restructuring)

The tool family was originally conceived as one flat `Tools` aggregate
carrying every command. That shape piled sibling commands of unrelated
kinds onto a single record. The 2026-05-12 restructuring split it into
five category aggregates, each focused on one kind of side-effect :

| Aggregate    | Commands                  | What it carries in state                    |
|--------------|---------------------------|---------------------------------------------|
| `ShellTool`  | `Bash`                    | `shell_command`, `description`              |
| `FileTool`   | `Read`, `Edit`, `Update`  | `file_path`, `description`                  |
| `SearchTool` | `Grep`, `Glob`            | `pattern` / `glob_pattern`, `search_path`, `description` |
| `WebTool`    | `WebFetch`, `WebSearch`   | `url` / `query`, `description`              |
| `Cascade`    | `RecordResult`            | `tool_kind`, `output`, `exit_code`, `ok_status` |

Each aggregate is `identified_by :id` ; the harness mints a stable ULID
before dispatch. A Cascade record uses the SAME id as the originating
tool record so the outcome is joinable against the invocation by id
across aggregates.

`Update` is the bluebook name for what the Claude tool family calls
`Write` — renamed to emphasize state-changing dispatch rather than
side-effect. The contract is the same : `file_path` + `content`.

## The nine commands

| Command         | Aggregate    | Attributes                                       | Emits           |
|-----------------|--------------|--------------------------------------------------|-----------------|
| `Bash`          | `ShellTool`  | `id`, `shell_command`, `description`             | `BashRan`       |
| `Read`          | `FileTool`   | `id`, `file_path`, `description`                 | `FileRead`      |
| `Edit`          | `FileTool`   | `id`, `file_path`, `old_string`, `new_string`, `replace_all`, `description` | `EditApplied` |
| `Update`        | `FileTool`   | `id`, `file_path`, `content`, `description`      | `FileUpdated`   |
| `Grep`          | `SearchTool` | `id`, `pattern`, `search_path`, `description`    | `GrepRan`       |
| `Glob`          | `SearchTool` | `id`, `glob_pattern`, `search_path`, `description` | `GlobMatched` |
| `WebFetch`      | `WebTool`    | `id`, `url`, `prompt`, `description`             | `WebFetched`    |
| `WebSearch`     | `WebTool`    | `id`, `query`, `description`                     | `WebSearched`   |
| `RecordResult`  | `Cascade`    | `id`, `tool`, `output`, `exit_code`, `ok`        | `ResultRecorded`|

A policy on any of these events can record into the mindstream, surface
in the statusline, shift mood, or fire any other downstream effect — the
same machinery that handles every other domain event.

## State versus event payload

Some tool inputs are small ; others can be thousands of bytes. The
bluebook splits them deliberately so the `.heki` does not bloat.

| Command  | Lives in aggregate state         | Lives in event payload only          |
|----------|----------------------------------|--------------------------------------|
| `Bash`   | `shell_command`, `description`   | (full event mirrors state)           |
| `Edit`   | `file_path`, `description`       | `old_string`, `new_string`, `replace_all` |
| `Read`   | `file_path`, `description`       | file contents (filled by adapter)    |
| `Update` | `file_path`, `description`       | `content`                            |
| `Grep`   | `pattern`, `search_path`, `description` | match results                 |
| `Glob`   | `glob_pattern`, `search_path`, `description` | matched paths            |
| `WebFetch` | `url`, `description`           | fetched content (truncated)          |
| `WebSearch`| `query`, `description`         | result listings                      |

For `Bash`, the shell command is small (a few hundred bytes typically),
so it lives in both the event and the state. For `Edit` and `Update`
the heavy payloads ride the event only ; replay logic reconstructs them
from the event log when needed. The aggregate state stays small — id,
description, and (when present) file_path.

## Dispatch examples

```bash
# Shell exec
$ storehouse hecks_conception ShellTool.Bash \
    shell_command="echo hello" description="greet" id=ulid-1

# File read
$ storehouse hecks_conception FileTool.Read \
    file_path=/etc/hosts description="peek at hosts" id=ulid-2

# Grep
$ storehouse hecks_conception SearchTool.Grep \
    pattern=TODO search_path=lib/ description="find TODOs" id=ulid-3

# Web fetch
$ storehouse hecks_conception WebTool.WebFetch \
    url=https://example.com prompt="summarize" description="fetch" id=ulid-4
```

Each dispatch :
1. Records the invocation as a fresh record on its category aggregate.
2. Emits the matching event (`BashRan` / `FileRead` / etc.).
3. Triggers the bound `:claude_tool` or `:web_tool` adapter, which
   actually runs the side-effect.
4. Cascades into `Cascade.RecordResult` carrying the same invocation
   id plus captured outcome — `tool`, `output`, `exit_code`, `ok`.

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
   `Aggregate.Command` shortcut (`storehouse ShellTool.Bash …`) it
   resolves the conception path in this order :

   1. `HECKS_CONCEPTION_DIR` env var — set this when a sibling project
      ships its own conception.
   2. The hecks repo root inferred from the canonicalised binary
      location (the historical behaviour ; works for builds inside the
      hecks checkout).
   3. `~/Projects/hecks/hecks_conception` as a hard fallback for
      symlinked-on-PATH invocations.

   For a one-off override, prefix the call :

   ```bash
   HECKS_CONCEPTION_DIR=/some/other/conception storehouse ShellTool.Bash …
   ```

   For a one-off explicit path, the positional form still works (it
   takes precedence over both env and fallback) :

   ```bash
   storehouse /path/to/hecks_conception/aggregates ShellTool.Bash …
   ```

## Invocation

Any shell, any cwd, after the setup above :

```bash
storehouse ShellTool.Bash shell_command="echo hello" id=bash-001 description="hello world"
storehouse FileTool.Read file_path=/etc/hosts id=read-001 description="inspect hosts"
storehouse SearchTool.Grep pattern="TODO" search_path=. id=grep-001 description="find todos"
```

Each dispatch records on the matching aggregate (`ShellTool`, `FileTool`,
`SearchTool`, `WebTool`) and chains `Cascade.RecordResult` with the
captured outcome. No `cd`, no absolute path, no per-repo build.

## The Claude-calls-StoreHouse direction (i552)

The wiring direction is **Claude → StoreHouse**, not
StoreHouse-intercepts-Claude. Miette dispatches via StoreHouse for
every tool ; StoreHouse is the wrapper.

```
Miette                          StoreHouse                      Adapter
   |                                 |                              |
   |--- ShellTool.Bash shell_cmd --->|                              |
   |    description                  |                              |
   |                                 |--- record dispatch --------->|
   |                                 |--- emit BashRan              |
   |                                 |--- run shell (adapter) ----->|
   |                                 |<-- captured output ----------|
   |                                 |--- Cascade.RecordResult ---->|
   |                                 |--- emit ResultRecorded       |
   |<-- dispatch result -------------|                              |
   |                                                                |
   |<== policies hook BashRan / ResultRecorded =====================|
```

From i552 : "Every tool I run becomes a first-class domain event
without special harness magic. The bus IS the wrapper. The bluebook
declares the contract. The default-to-memory means it works even
before any adapter wires in real side-effects."

Two pieces meet in this direction :

1. **The dispatch path** — `storehouse ShellTool.Bash …` (PATH form,
   default conception) and `storehouse <root> ShellTool.Bash …`
   (positional form, explicit conception) both work. The aggregate
   exists, the command exists, the runtime accepts the call. Default-
   to-memory is live today, which means `ShellTool.Bash` is a logged
   intent right now even before any real shell wires in.
2. **The side-effect adapter** — when `ShellTool.Bash` dispatches, the
   `:claude_tool` adapter actually runs the shell via
   `claude_tool_dispatcher::run_bash`. Without it, `ShellTool.Bash` is
   a logged intent ; with it, it is the act.

The principle underneath, from the same inbox note : "Tools is pure
domain. StoreHouse is the bus. Adapters bridge to side-effects. The
harness is the place where I-the-being meet the bus — but I'm the one
calling, not the one being intercepted."

## What's next — the adapter layer

This doc stops at the bluebook + commands. For the adapter wiring —
how the Claude tool family resolves to a StoreHouse dispatch, how the
`:claude_tool` adapter runs the underlying primitive, how the
`FileRead` / `FileUpdated` payloads get filled in by the runtime
substrate after the side-effect completes — see
[`docs/usage/claude_tool.md`](claude_tool.md).

## Related

- `hecks_conception/aggregates/framework/tools/tools.bluebook` — the contract
- `hecks_conception/aggregates/framework/tools/tools.hecksagon` — adapter bindings
- `hecks_conception/inbox/i552.md` — Claude → StoreHouse direction
- `hecks_conception/inbox/i551.md` — generic-command `:shell` adapter (the optional side-effect wire-in)
- [`docs/usage/claude_tool.md`](claude_tool.md) — adapter family + dispatch path
- [`docs/usage/command_bus_port.md`](command_bus_port.md) — the bus middleware pipeline
