# `hecks init` writes the starter files of a new domain

**Status:** Proposed. Date: 2026-10-03. Nothing here is built; this ADR asks for a decision before any code.

## Context

[ADR 0071](0071-the-first-external-target-is-a-standalone-rules-service.md) sets the first adoption test: an outside team defines a bluebook, deploys it, and calls it, using only the docs. The own-domain guide (`docs/implemented/guides/your-own-domain.md`) is where that starts, and its first step is to make a directory, then hand-type three files into it: a `.bluebook`, a `.world` and an `environments/memory.world`. Getting the layout wrong (the folder must be `bluebook/`, the files must share a basename, the overlay must sit in `environments/`) fails at the next command with an error about something else.

Rails solves this with `rails new`. hecks has nothing that makes a domain. Everything that touches a domain already assumes one exists.

The obvious name, `hecks project init`, is a poor fit. "Project" is already doing two jobs: `hecks project_rust`, `hecks project_cli` and `hecks deploy project` all mean "derive something from a bluebook", and in a clone "the project" also means this repository. A third meaning, "create a domain", would make each of the other two harder to read.

The mechanism to build this already exists. The Hecks domain's `Door` aggregate has a `ProjectCli` command that writes launcher files: it records a request, a policy asks the `Workspace` port, and the `LocalFiles` adapter does the writing and nothing else does (`lib/hecks/hecks/custodian.bluebook`, `lib/hecks/hecks/adapters/local_files.rb`). That is the shape [ADR 0080](0080-bin-scripts-become-adapters-on-a-hecks-bluebook.md) section 11 prescribes for any command whose effect happens outside the runtime.

## Decision

1. **Add one command, `Init`, to the Hecks domain, spelled `hecks init <Name>`.** Not `hecks project init`, and not `hecks new`. It joins the `Door` aggregate beside `ProjectCli`, asks the existing `Workspace` port, and is written by `LocalFiles`. No new aggregate, port or adapter.
2. **The user chooses the persistence adapter, with a flag.** `hecks init Lending --adapter=<name>` takes the name of any adapter the registry knows (`Memory`, `SqlitePersistence`, `Postgres`, `PostgresEra`, `Heki`), read from the registry and not hard-coded in `init`, so an adapter added later is accepted without a change here. An unknown name is refused with the list of known ones. The launcher already rewrites `--adapter=<name>` into the command's `adapter` argument (`Doors::CliDoor`), so the flag needs no new parsing, only an optional `adapter` argument on `Init`. When the flag is absent, `init` uses the default named in Open items.
3. **It writes a domain directory that runs as soon as it is written.** For `hecks init Lending` it creates `lending/` (or the directory named by `--dir=<path>`) holding:
   - `bluebook/lending.bluebook`: a small valid domain with one aggregate, a value object, a lifecycle and two commands, which `hecks docs` reads and `hecks console` runs;
   - `bluebook/lending.world`: `default_adapter` set to the chosen adapter, plus the settings that adapter needs. `SqlitePersistence` and `Heki` get a data path under `data/`. `Postgres` and `PostgresEra` get a `default_database` URL. `Memory` needs nothing;
   - for an adapter that needs a server (`Postgres`, `PostgresEra`), `bluebook/environments/memory.world`: the overlay that swaps the adapter to Memory, so the first run needs no database. An adapter that runs without one gets no overlay.

   No `.hecksagon` is written: `default_adapter` binds every aggregate, and a hecksagon is for what that cannot say.
4. **It never replaces anything.** If the target directory already holds a bluebook, or any file `init` would write, it refuses and names the file. A half-written domain is not left behind: it checks every target before writing the first.
5. **It prints the next steps** (`hecks docs <dir>/bluebook`, `hecks console subject=<dir>`) so the output of `init` is the start of the guide.
6. **A spec boots what `init` writes.** The starter is data kept where the adapter can read it, and a spec runs `hecks init` into a temporary directory and boots the result, so the starter cannot rot into something that does not run. The own-domain guide's first step then becomes one command followed by the same edit-and-run loop.

7. **It also has an interactive mode, and the mode establishes the domain's first aggregate and its first command.** Run at a terminal with a choice left out, `hecks init` asks for it, in this order: the domain's name; the main thing it keeps track of (the aggregate) and the field that identifies one; the first thing that happens to it (a creating command) and what that command announces (its event); the adapter (a numbered list read from the registry, with the default marked); and the directory. The files written are then the user's own model, not a stock example. Each question defines its term once, in the question where it first appears. Each answer has a flag (`--aggregate=Book --identified-by=isbn --command=Shelve --emits=BookShelved --adapter=SqlitePersistence --dir=lending`), so the same line runs with no prompt, and the session ends by printing it. A flag that was given is never asked about. With no terminal on standard input (a pipe, CI) `init` takes the defaults and never waits; with no aggregate given it writes the neutral shelf-and-lend starter of decision 3. Asking is IO, so it happens in the `Terminal` port's adapter, which already runs the interactive console, and not in the command: `Init` records the choices that were made, and a policy asks the adapter for the missing ones before the files are written. Nothing is written until the last confirmation, so quitting leaves nothing behind. Interviewing a domain expert about the whole domain (events, roles, rules, vocabulary) is larger, and is left to its own ADR.

## Consequences

- A newcomer goes from a clone to a running domain of their own in one command, without a layout to get right first.
- The own-domain guide gets shorter and its hand-typed files become the starter's. The Lending example in it stays as the thing you edit toward.
- One more verb in the Hecks domain's command list, so `hecks` prints it, and the docs that list verbs (the README Install section and `docs/tools.md`) gain a line.
- The starter's `default_database` and any `deployed_to` block are a choice made on the reader's behalf. Decision 2 writes a database URL and no `deployed_to`; whether it should write one is open below.
- `init` writes files in the directory the operator stands in, as `ProjectCli` does. It never touches the clone's own tree unless the operator points it there.

## Alternatives considered

- **`hecks project init`.** Reads naturally next to Rails but adds a third meaning to "project" (see Context).
- **`hecks new <Name>`.** Closest to Rails. Rejected for now only because `init` was asked for; the choice costs nothing to revisit.
- **A `hecks generate` family.** Right if hecks later scaffolds aggregates and commands inside an existing domain. Premature for one command, and it can be added without moving `init`.
- **Docs only (what exists).** No risk, but the layout stays something a newcomer can get wrong, and the first command in the guide cannot be a one-liner.

## Open items

- Which fields does the first command take? Asking for each field (`name:type`) makes the starter complete but lengthens the session; asking for the name and event only gives a command with no arguments to extend. Starting with the identifying field alone is the shortest version that runs.
- How is a past-tense event name made? Guessing `Shelve` to `BookShelved` is wrong often enough that the session asks, with a guess shown as the default.
- What switches the prompts off when a terminal is attached but the user wants none: a `--yes` flag, `--no-interactive`, or both? Rails-style generators lean on `--force` and `--skip`, which mean something else here (`init` never replaces).
- Which adapter is the default when `--adapter` is omitted and there is no terminal to ask? `SqlitePersistence` runs with no server, no environment variable and no overlay, and keeps its data between runs, which suits a first session. `Postgres` is what the Lambda host serves (it refuses a domain bound to anything else), so a reader who goes on to deploy would have to change it. `init` could print that when a non-Postgres adapter is chosen.
- Does the gem's own command set (ADR 0066) carry `init`? It is most useful to someone who has no clone, but the rest of the own-domain path (`deploy project`, `sam build`) still needs one.
- Should the starter include a `deployed_to("AwsLambda")` block? It makes `hecks deploy project` work immediately, and commits the reader to a region and Lambda before they asked.
- May `--dir=` point inside the clone? The deploy procedure says to keep a service outside it, so `init` could refuse, or warn.
- Should `init` also write a `.gitignore` or a README for the new domain?
