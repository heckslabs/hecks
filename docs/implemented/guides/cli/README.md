# The command line, by task

The modules are the ones
[ADR 0163](../../../decisions/0163-hecks-is-one-context-in-task-modules-and-a-bang-is-the-only-sign-of-a-write.md)
groups the commands into. Where a module's commands are not yet grouped that way, its page says so.*

Run `hecks` with no arguments for the everyday commands, `hecks <module>` for one task, and
`hecks <command> --help` for what one command wants and every way it refuses.

## The words

**A bluebook** is a domain, declared: its aggregates, commands, events and policies. It names no
database, clock or file. A **hecksagon** is the wiring: which adapters the domain plugs into.

**A command** changes something. It is written with a trailing bang: `Aggregate.verb!`. A command
either finishes and says what it did, or refuses and says why.

**A query** only reads. It has no bang: `Aggregate.name`.

**A run** is one thing an operator asked for and how it ended. Commands such as `GateRun.gate!`
record a run, so you can ask later what happened.

**Audience** says who a command is listed for: `person` for you at a terminal, `agent` for a
background session, `ci` for a pipeline, `record` for bookkeeping that a run writes about itself.
It decides what is listed, not who may run it.

## The bang rule

A name with a bang changes something. A name without one only reads. A line that names a command
without its bang is refused, with the bang spelling in the reply.

## Modules

- [operate](operate.md): run a domain and look inside it
- [check](check.md): is it right?
- [test](test.md): run the specs and fuzzers
- [build](build.md): compile and regenerate
- [deliver](deliver.md): take finished work into the shared line
- [release](release.md): certify, publish and pin versions
- [migrate](migrate.md): move a store between shapes
- [evolve](evolve.md): change the language and rewrite to match
- [start](start.md): begin a domain or a project
- [serve](serve.md): open something on a port or stdio
- [find](find.md): read the code
- [delegate](delegate.md): hand work to a background session

## Flags

Two kinds of flag exist, and each has one home.

A launcher flag is accepted by every command, whatever its bluebook declares: `--wait`, `--confirm`, `--plan`, `--json`, `-q`, `-v` and `--help`. A command that has nothing to wait for accepts `--wait` and ignores it, so a script can pass it everywhere.

A command's own flag is a Boolean argument its bluebook declares, and it appears in that command's `--help`. The launcher gives it no meaning of its own.

A flag that no command declares is refused with exit 2, and the message names the flag and points at the command's help.
