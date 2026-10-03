# `hecks init` writes the stub files of a new domain

**Status:** Proposed. Date: 2026-10-03. Nothing here is built; this ADR asks for a decision before any code. `init` only writes stubs and asks nothing. The guided, AI-driven way to start a domain is a different command, `hecks interview`, in [ADR 0088](0088-an-ai-driven-interview-records-what-an-expert-says-and-drafts-the-first-domain.md).

## Context

[ADR 0071](0071-the-first-external-target-is-a-standalone-rules-service.md) sets the first adoption test: an outside team defines a bluebook, deploys it, and calls it, using only the docs. The own-domain guide (`docs/implemented/guides/your-own-domain.md`) is where that starts, and its first step is to make a directory, then hand-type three files into it: a `.bluebook`, a `.world` and an `environments/memory.world`. Getting the layout wrong (the folder must be `bluebook/`, the files must share a basename, the overlay must sit in `environments/`) fails at the next command with an error about something else.

Rails solves this with `rails new`. hecks has nothing that makes a domain. Everything that touches a domain already assumes one exists.

The obvious name, `hecks project init`, is a poor fit. "Project" is already doing two jobs: `hecks project_rust`, `hecks project_cli` and `hecks deploy project` all mean "derive something from a bluebook", and in a clone "the project" also means this repository. A third meaning, "create a domain", would make each of the other two harder to read.

The mechanism to build this already exists. The Hecks domain's `Door` aggregate has a `ProjectCli` command that writes launcher files: it records a request, a policy asks the `Workspace` port, and the `LocalFiles` adapter does the writing and nothing else does (`lib/hecks/hecks/custodian.bluebook`, `lib/hecks/hecks/adapters/local_files.rb`). That is the shape [ADR 0080](0080-bin-scripts-become-adapters-on-a-hecks-bluebook.md) section 11 prescribes for any command whose effect happens outside the runtime.

## Decision

1. **Add one command, `Init`, to the Hecks domain, spelled `hecks init <Name>`.** Not `hecks project init`, and not `hecks new`. It joins the `Door` aggregate beside `ProjectCli`, asks the existing `Workspace` port, and is written by `LocalFiles`. No new aggregate, port or adapter.
2. **The user chooses the persistence adapter, with a flag.** `hecks init Lending --adapter=<name>` takes the name of any adapter the registry knows (`Memory`, `SqlitePersistence`, `Postgres`, `PostgresEra`, `Heki`), read from the registry and not hard-coded in `init`, so an adapter added later is accepted without a change here. An unknown name is refused with the list of known ones. The launcher already rewrites `--adapter=<name>` into the command's `adapter` argument (`Doors::CliDoor`), so the flag needs no new parsing, only an optional `adapter` argument on `Init`. **The default is `SqlitePersistence`:** it needs no server, no environment variable and no overlay, and keeps its data between runs, which suits a first session. The Lambda host serves only Postgres, so when a non-Postgres adapter is chosen `init` prints that `--adapter=Postgres` is what a deployment needs.
3. **It writes a stub domain directory that runs as soon as it is written.** For `hecks init Lending` it creates `lending/` (or the directory named by `--dir=<path>`) holding:
   - `bluebook/lending.bluebook`: a stub that is a valid domain and nothing more. It has a `vision`, one placeholder aggregate (`Example`) with an identifying field, and one creating command, each marked with a `TODO` comment to rename or replace. `hecks docs` reads it and `hecks console` runs it, so the first edit starts from something that works;
   - `bluebook/lending.world`: `default_adapter` set to the chosen adapter, plus the settings that adapter needs. `SqlitePersistence` and `Heki` get a data path under `data/`. `Postgres` and `PostgresEra` get a `default_database` URL. `Memory` needs nothing. **No `deployed_to` block is written:** it would commit the reader to a region and to Lambda before they chose, and the own-domain guide shows how to add it;
   - for an adapter that needs a server (`Postgres`, `PostgresEra`), `bluebook/environments/memory.world`: the overlay that swaps the adapter to Memory, so the first run needs no database. An adapter that runs without one gets no overlay;
   - for an adapter that writes local data (`SqlitePersistence`, `Heki`), a `.gitignore` holding `data/`. No README is written: the guide says what a README would.

   No `.hecksagon` is written: `default_adapter` binds every aggregate, and a hecksagon is for what that cannot say.
4. **It never replaces anything.** If the target directory already holds a bluebook, or any file `init` would write, it refuses and names the file. A half-written domain is not left behind: it checks every target before writing the first.
5. **It prints the next steps** (`hecks docs <dir>/bluebook`, `hecks console subject=<dir>`) so the output of `init` is the start of the guide.
6. **A spec boots what `init` writes.** The stub is data kept where the adapter can read it, and a spec runs `hecks init` into a temporary directory and boots the result, so the stub cannot rot into something that does not run. The own-domain guide's first step then becomes one command followed by the same edit-and-run loop.
7. **`init` asks nothing.** It takes its choices from flags (`--adapter`, `--dir`) and defaults, so the same line works at a terminal, in a script and in CI, and it never waits for input. Anything that needs a conversation about what the domain is, such as its first aggregate and commands, belongs to `hecks interview` ([ADR 0088](0088-an-ai-driven-interview-records-what-an-expert-says-and-drafts-the-first-domain.md)), which is a separate command and not a mode of this one. The two share the plumbing that writes the `.world`, the overlay and the `.gitignore` and checks that nothing is replaced, but not the bluebook: `init` writes a fixed stub, and `interview` renders one from accepted findings.
8. **`--dir` may point inside the clone, with a warning.** The deploy procedure keeps a service outside the clone, but a maintainer may reasonably start a domain in `examples/`, so `init` warns and goes on.
9. **The gem's own command set carries `init`.** It is the first thing someone with only `gem install hecks` and no clone would run, and it writes plain files. The rest of the own-domain path (`deploy project`, `sam build`) still needs a clone, and the guide says so. This adds one verb to what [ADR 0066](0066-the-gem-ships-a-hecks-executable-and-dev-tooling-stays-in-the-repo.md) lists the gem as shipping.

## Consequences

- A newcomer goes from a clone, or from the gem alone, to a running stub of their own in one command, without a layout to get right first, and edits it from there.
- The own-domain guide gets shorter: its first step becomes `hecks init Lending`, then editing the stub into the Lending domain it already shows.
- One more verb in the Hecks domain's command list, so `hecks` prints it, and the docs that list verbs (the README Install section and `docs/tools.md`) gain a line.
- The default adapter, `SqlitePersistence`, is not the one a Lambda deployment uses. The note `init` prints, and the guide's deploy step, carry that.
- `init` writes files in the directory the operator stands in, as `ProjectCli` does, and never replaces any.

## Alternatives considered

- **`hecks project init`.** Reads naturally next to Rails but adds a third meaning to "project" (see Context).
- **`hecks new <Name>`.** Closest to Rails. Rejected for now only because `init` was asked for; the choice costs nothing to revisit.
- **A `hecks generate` family.** Right if hecks later scaffolds aggregates and commands inside an existing domain. Premature for one command, and it can be added without moving `init`.
- **Postgres as the default adapter.** What the Lambda host serves, but it needs a running server for the first command, which is the problem this ADR exists to remove.
- **Prompts in `init`.** An earlier draft had `init` ask for the first aggregate and command. Dropped: it overlaps the interview, and a stub writer that asks nothing is simpler, scriptable and never blocks.
- **Docs only (what exists).** No risk, but the layout stays something a newcomer can get wrong, and the first command in the guide cannot be a one-liner.

## Open items

- The placeholder aggregate's name. `Example` is neutral but every user renames it; deriving one from the domain name (`Lending` gives a `Lending` aggregate) avoids the rename and reads oddly.
- Whether the stub's `TODO` comments follow a fixed phrase that a later command could find.
