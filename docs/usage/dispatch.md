# StoreHouse dispatch

StoreHouse is the bus over the bluebook conception. Every callable phrase —
commands and queries, in every surface (Spring REPL, Glass palette, the
conversation surface, the bin-buddy command bus, future hosts) — routes through
it. The CLI binary that fronts the bus is `storehouse`.

## The four-segment phrase

The canonical calling convention is four `::`-separated segments :

```
<app>::<domain>::<Aggregate>::<Command>
```

- `app`       — the project folder (e.g. `bin-buddy`, `miette`, `hecks-conception`).
                Inferred at compile time from the bluebook's location ; not
                declared in the source.
- `domain`    — the sub-folder grouping under the app (`notifications`,
                `consciousness`, `storehouse`).
- `Aggregate` — the aggregate declared in the bluebook.
- `Command`   — the command on that aggregate. PascalCase.

The same shape covers queries — the fourth segment is just lowercase. Case
disambiguates kind, the way every other Hecks convention disambiguates :

```
bin-buddy::notifications::Notifications::SendEmail   # command (PascalCase)
bin-buddy::notifications::Notifications::last_status # query   (snake_case)
hecks-conception::storehouse::Dispatch::Route        # command
hecks-conception::storehouse::Lexicon::compiled_at   # query
miette::framework::Tools::Bash                       # command
```

From `dispatch.bluebook` :

> "must be app::domain::Aggregate::Command (4 non-empty segments)"

## Dispatching from the CLI

The `storehouse` binary takes an aggregates directory (or single bluebook
file) and a fully-qualified address. Attributes follow as `key=value` pairs :

```bash
storehouse <aggregates_dir> <Domain>::<Aggregate>.<Command> attr1=value1 attr2=value2
```

**i560 v2 (2026-05-12)** — the CLI accepts ONLY the canonical
fully-qualified form `Domain::Aggregate.Command` (commands, PascalCase
trailing token) or `Domain::Aggregate.query_name` (queries, snake_case
trailing token). The short forms (`Aggregate.Command`, bare `Command`)
are rejected with a helpful error naming the new form. Internal
cascade dispatch through `Runtime::drain_policies` still resolves the
legacy forms — bluebook `trigger_command` declarations keep working.

The `Domain` segment matches an aggregate's `context` (bluebook
namespace, e.g. `Tools`, `Macrophage`, `Boot`) OR the bluebook's
`category` (the directory under `aggregates/`, e.g. `discipline`,
`framework`, `world`). Case-insensitive.

PascalCase trailing token routes as a command ; snake_case routes as
a query (read-only, returns JSON).

## Self-ref convention

Commands that operate on an existing record carry a `reference_to(AggName)`
attribute pointing back at the aggregate they live on. Two equivalent ways
to pass the id at the CLI :

```bash
# Named — the reference's snake_case form of the aggregate name :
storehouse aggregates/ BinBuddy::Notifications.MarkSent notifications=01HXYZ...

# Universal — the bare `id=` fallback works for every aggregate :
storehouse aggregates/ BinBuddy::Notifications.MarkSent id=01HXYZ...
```

The runtime computes `to_snake_case(aggregate_name)` and looks for that key
first ; if absent it falls back to `id`. Both reach the same record.

For `Create*` / `Open*` / `Register*` / `Add*` / `Place*` commands the id is
minted by the runtime — you don't pass one in.

## Where the heki state lives

The first positional argument is the **aggregates directory** (where the
bluebooks live). The **heki state directory** (where dispatched events and
aggregate snapshots persist) resolves separately, in this order :

1. If a sibling `.world` file declares `heki { dir "..." }`, that path wins.
   The differential fuzzer leans on this for per-seed isolation —
   `/tmp/fuzz-<seed>/aggregates/` + `/tmp/fuzz-<seed>/fuzz.world` keep each
   seed in its own tree.
2. Otherwise the canonical `storehouse::heki::resolve_info_dir()` helper
   resolves the repo-root-anchored info dir (HECKS_INFO-aware).

This is `find_world_heki_dir` in `rust/src/main.rs` — bluebook-first, with a
safe fallback for callers without a sibling world file.

## Three concrete dispatches

### 1. Run a shell command through `Tools.Bash`

`miette::framework::Tools::Bash` is wired to a `:claude_tool` adapter that
shells out via the kernel-floor `claude_tool_dispatcher` (commit `35e88dc2`,
"wire :claude_tool adapter into dispatch") :

```bash
storehouse hecks_conception/aggregates/framework/tools \
  Tools::Tools.Bash shell_command='echo hello' description='greet'
```

Output (trimmed) :

```json
{"ok":true,"aggregate":"Tools","id":"01H...","state":{"shell_command":"echo hello",...}}
```

Stderr carries the adapter's outcome log. The runtime persists a `BashRan`
event in the configured heki dir, and the shell actually runs.

### 2. Read a query

```bash
storehouse hecks_conception/storehouse Storehouse::Lexicon.compiled_at
```

Snake_case fourth segment ⇒ the dispatcher routes via
`Runtime::resolve_query` and prints the result directly (no event, no
persistence).

### 3. Re-dispatch into an existing record

```bash
storehouse aggregates/ BinBuddy::Notifications.MarkSent id=01HXYZ_CUSTOMER_NOTIF
```

The runtime locates the `Notifications` record at that id (universal `id=`
fallback ; equivalent to passing `notifications=01HXYZ_CUSTOMER_NOTIF`),
applies the lifecycle transition declared in the bluebook, persists the
new state, and re-emits the event.

## Where the convention is enforced

- `hecks_conception/storehouse/dispatch.bluebook` — Phrase rule : 4 non-empty
  `::`-separated segments.
- `hecks_conception/storehouse/lexicon.bluebook` — same Phrase shape, plus
  `app` as a first-class field on every entry for CommandBus filtering.
- `hecks_conception/storehouse/query.bluebook` — Path rule : four-segment,
  trailing attribute name (or named-query lowercase name).
- `rust/src/main.rs::dispatch_hecksagon` — the CLI entrypoint that boots a
  Runtime, resolves the phrase against the loaded lexicon, validates attrs,
  and routes to `Runtime::dispatch` (command) or `Runtime::resolve_query`
  (query).
- `rust/src/runtime/command_dispatch.rs::find_self_ref_res` — the self-ref
  resolver that matches `reference_to(AggName)` attributes against the
  snake_case aggregate name (with `id=` as the universal fallback).

## See also

- [Command Bus Port](command_bus_port.md) — the HTTP adapter that puts the
  bus behind a route handler.
- [CLI subcommand catalog](cli_subcommand_catalog.md) — every other
  `storehouse <subcommand>` form, declared as data.
- `hecks_conception/inbox/i528.md` — the storehouse arc design memo, with
  the eight locked decisions behind the four-segment convention.
