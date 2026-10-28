# Hecks defaults to Memory, and a local hecksagon opts in

**Status:** Accepted. Built: `Ports::Persistence::BindingPolicy`, `Adapters::FolderOverlay`
(`lib/hecks/adapters/driven/folder_overlay.rb`), `hecks.world` and `hecks config`. On a branch, not
released. Date: 2026-10-27.

## Context

`CLAUDE.md` says persistence defaults to memory: a domain uses the Memory adapter unless its
hecksagon explicitly wires another. The Hecks domain itself did the opposite. `hecks.world`
declared `default_adapter "PostgresEra"` and a database from `HECKS_DATABASE`, so the launcher
could not boot without a Postgres `hecks` database. The `console` command was special-cased as a
"memory command" to get around that, every development run set `HECKS_ENVIRONMENT=memory`, and a
checkout booted against another copy's database could mint an era that copy then refused. The push
train is the copy whose runs must outlive the process; almost no other copy needs that.

Memory as the default is a hexagonal hallmark: the domain boots with nothing behind it, and
infrastructure is something a copy opts into. Nothing should have to say "Memory" to get it.

## Decision

Every decision says which side it is on.

1. **Hecksagon: Memory is the framework default, so nothing names it.** Neither `hecks.world` nor
   `hecks.hecksagon` mentions persistence. A hecksagon that wires none leaves its aggregates in
   Memory. One that binds some aggregates and forgets another is still refused as a forgotten
   decision; a bind to Memory counts as no wiring.
2. **Hecksagon: a root `persisted_by` reaches the chapters its domain attaches.**
   `BindingPolicy.resolve` takes, in order, the aggregate's own bind, its chapter's root default,
   the root default of a domain that attaches the chapter, the world's `default_adapter`, then
   Memory. Two attaching domains that default to different adapters are refused.
3. **Hecksagon and world: a local pair opts a copy in.** A copy, or a client's working directory,
   adds `hecks.local.hecksagon` (`persisted_by "PostgresEra"`) and `hecks.local.world` (the
   `default_database`, `mint_eras`). `.gitignore` keeps them out of the repository, so one copy
   persists without any other copy knowing. `environments/local.*` keeps working in its older form.
4. **Adapter: the loader reads them last.** `Adapters::FolderOverlay#load_overlay` loads the copy's
   `environments/local.*`, then `*.local.hecksagon` and `*.local.world` beside the domain and in the
   working directory, then a named environment's overlay. The base glob skips them, so they cannot
   load before the file they override.
5. **`HECKS_ENVIRONMENT=memory` stays an override.** It selects Memory even when local files name a
   store, for specs and pull-request runs.
6. **The variable is only a courier.** `HECKS_DATABASE` is no longer read by the base world. A
   deployed box whose password arrives at runtime writes a local world that reads it with
   `default_database ENV.fetch("HECKS_DATABASE")`, so a secret still stays out of a file.
7. **A named store with no bind warns.** A world that names a database or persistence settings
   while no hecksagon binds persistence prints one boot notice: its aggregates are in Memory.

## Consequences

- A development run needs no environment variable and no database. `hecks config` reports where
  the database came from: a local file, or the world itself.
- The copy that runs the push train must carry an `environments/local.hecksagon` with
  `persisted_by "PostgresEra"` before it refreshes onto this change, or it runs in Memory.
- Process managers lose their saga state on restart in Memory; the existing boot warning says so.
- The attached-chapter default is resolved in the Ruby runtime; Rust reads the resolved bind from
  the exported IR, so the two agree without a Rust change.
- The deploy recipes name the local world and hecksagon where they used to name `HECKS_DATABASE`,
  and `hecks stores` and `hecks history` say on standard error when nothing is persisted.
- The launcher's `memory_commands` stays. It makes `console`, `init` and `interview` run on Memory
  even in a copy a local hecksagon has opted in, so a person at the terminal never boots, or mints
  an era in, the copy's database; it also makes them wait and say why they were refused, which has
  nothing to do with persistence.

## Rejected alternatives

- **`default_adapter "Memory"` in the base world.** It says out loud what the framework already
  does, and a copy then has to override a value instead of adding one.
- **A switch in the world on whether `HECKS_DATABASE` is set.** It puts a conditional in a
  declarative file, makes the mode depend on a variable nobody sees, and a world with a conditional
  does not parse the same in Ruby and Rust.
- **A named environment such as `HECKS_ENVIRONMENT=postgres`.** The variable is shared by every
  domain booted in a process, so opting the launcher in would opt every other domain in with it.
- **A hand-listed loop of chapters in the local file.** It silently falls back to Memory when a
  chapter is added.
