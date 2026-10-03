# Migrating from Hecks 2.x to 3.0

3.0.0 turned every `bin/` script into a command on the Hecks domain (ADR 0080). Most of what
breaks is a call spelled `bin/<name>`. Each item below says what changed and what to do. The
CHANGELOG entry for 3.0.0 has the full wording.

## 1. Replace `bin/<name>` with `hecks <verb>`

The `bin/` directory is gone. The launcher is `exe/hecks`, which the gem ships and `hecks `
regenerates. The verb a script became is in [docs/tools.md](tools.md), and `hecks <verb> --help`
says what it takes. Arguments are projected from the command, so flags and argument order can
differ from the old script: `bin/compact` is `hecks era.compact <domain> [aggregates=A,B] --confirm`.

Two launcher names differ from their command: `hecks mcp` runs `ServeMcp` (also `hecks door.serve_mcp`)
and `hecks console` runs `OpenConsole` (also `hecks operation.open_console`).

Look in these places in your project:
- CI jobs, git hooks, Makefiles and shell scripts that call `bin/<name>`.
- Docs that quote those calls.
- A generated deploy `Makefile` or script: regenerate it with `hecks deploy recipe.project <domain>`, which
  now writes `hecks <verb>` calls.

A check that used to print a result and exit now takes `--wait`: it re-reads the run it recorded and
exits 1 on a failure state (`flagged`, `failed`, `drifted`, `unreachable`, `refused`, `faulted`,
`halted`, `stopped`, `abandoned`, `red`, `needs_fix`). Without `--wait` the status is unchanged.

## 2. Rename `Hecks::Facade` to `Hecks::Doors`

`Surface` is now `Doors::RubyDoor`, and the MCP door lives beside it. `install_facade:` is now
`install_doors:`. The old names still work in 3.0 and warn; they are removed in 3.1.0. Regenerate
launchers with `hecks `.

## 3. Reach Hecks-chapter constants through `Hecks::Domain`

`hecks.bluebook` declares `namespace "Hecks::Domain"`, so `Release`, `Codemod`, `Corpus`, `Fuzzing`
and `Kernel` no longer collide with the gem's own `Hecks` module. Code that used `Hecks::<Name>` for
a Hecks-chapter constant uses `Hecks::Domain::<Name>`.

## 4. Move `answered_by` into the hecksagon

A `query` no longer names the port that answers it:
- In the hecksagon, bind the query to its port: `answers_query "Name"`.
- In the bluebook, declare the answer's shape: `returns Name` (or `returns list_of(Name)`) for a value
  object of the same aggregate.

Every row an adapter answers is built as that value object before it enters the domain. At boot a
query must have exactly one answer path: it filters the aggregate's records, or it returns a value
object that one port binds. A domain with a Rust target is refused by `hecks model_check`
(`:external_query`) for each bound query, because only the Ruby runtime asks an adapter.

## 5. Use the renamed lifecycle commands

`Era.Admit` is `Era.Permit`, and `Release.Publish` is `Release.MarkPublished`. `Release.Verify` now
also runs from `verified`. Anything that dispatches the old names by string uses the new ones.

## 6. Approve era edges with a committed file

An edge is approved by `translations/<from>-<to>.approval`, a JSON file beside the edge that the
host reads at its next boot. It is valid while its digest matches the edge, and while its
`host_version` has the same `major.minor` as the running host's Hecks release. A journal approval
bound to the tip still satisfies the check, so an edge approved before 3.0.0 keeps booting. Write
new approvals as the file.

## 7. Expect a larger gem

The gem ships `rust/` (without `rust/tests/`, `rust/src/generated/` and `target/`) and `exe/hecks`,
so `hecks build.build_wasm` and the other Build commands work from an installed gem. A build copies the
workspace to `.hecks/rust/<version>/` and never writes into the gem. Anything that read the gem's
file list to leave the tooling out no longer can.

## Security fixes since 3.0.0

Upgrade to 3.0.3 or later, not 3.0.0. 3.0.1 to 3.0.3 closed: `GET /members` and
`GET /newsletter/subscribers` now require an Admin or Owner (a client that read them with a plain
member's cookie, or none, must use an admin's); `uses_embryonaut_bluebook` refuses a package name
outside `[a-z][a-z0-9_]*`; and code generation refuses declared names that are not plain identifiers.

## Check your upgrade

1. `bundle update hecks`, then `hecks ` to regenerate the launcher.
2. `hecks model_check --wait` and `hecks regeneration_run.regenerate_corpus --check --wait` exit 0.
3. Run your suite with `HECKS_ENVIRONMENT=memory` if no Postgres is reachable.
