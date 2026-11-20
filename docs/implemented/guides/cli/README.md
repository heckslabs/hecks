# The command line, by task

<!-- prose anchor="The command line, by task" purpose="concept" mentions="adr:0163" supports="doc:docs/decisions/0163-hecks-is-one-context-in-task-modules-and-a-bang-is-the-only-sign-of-a-write.md" -->
The modules are the ones
[ADR 0163](../../../decisions/0163-hecks-is-one-context-in-task-modules-and-a-bang-is-the-only-sign-of-a-write.md)
groups the commands into. Where a module's commands are not yet grouped that way, its page says so.*

Run `hecks` with no arguments for the everyday commands, `hecks <module>` for one task, and
`hecks <command> --help` for what one command wants and every way it refuses.

## The words

<!-- prose anchor="The words" purpose="concept" mentions="command:GateRun.gate!" supports="doc:docs/decisions/0163-hecks-is-one-context-in-task-modules-and-a-bang-is-the-only-sign-of-a-write.md" -->
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

<!-- prose anchor="The bang rule" purpose="concept" supports="doc:docs/decisions/0163-hecks-is-one-context-in-task-modules-and-a-bang-is-the-only-sign-of-a-write.md" -->
A name with a bang changes something. A name without one only reads. A line that names a command
without its bang is refused, with the bang spelling in the reply.

## Modules

<!-- generated:begin cli section=index -->
- [build](build.md): Compile and regenerate.
- [check](check.md): Is it right? Gate, model check, style, inspection and audit.
- [delegate](delegate.md): Hand work to a background session.
- [deliver](deliver.md): Take finished work into the shared line.
- [evolve](evolve.md): Change the language and rewrite to match.
- [find](find.md): Read the code: search the checkout's text, read a file, outline what it declares, find where a name is declared. Read the record: search work items, findings and decisions by their words.
- [migrate](migrate.md): Move a store between shapes.
- [operate](operate.md): Run a domain and look inside it.
- [release](release.md): Certify, publish and pin versions.
- [serve](serve.md): Open something on a port until it is stopped: the Composer, a rendered example, or a static site.
- [start](start.md): Begin a domain or a project.
- [test](test.md): Run the specs and fuzzers.
<!-- generated:end cli -->

## Flags

<!-- prose anchor="Flags" purpose="concept" supports="code_file:lib/hecks/adapters/driving/launcher_options.rb" -->
Two kinds of flag exist, and each has one home.

A launcher flag is accepted by every command, whatever its bluebook declares: `--wait`, `--confirm`, `--plan`, `--json`, `-q`, `-v` and `--help`. A command that has nothing to wait for accepts `--wait` and ignores it, so a script can pass it everywhere.

A command's own flag is a Boolean argument its bluebook declares, and it appears in that command's `--help`. The launcher gives it no meaning of its own.

A flag that no command declares is refused with exit 2, and the message names the flag and points at the command's help.
