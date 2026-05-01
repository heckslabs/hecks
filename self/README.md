# self/

*Self* — here Hecks describes itself in its own DSL, *à la manière de* a body learning its own anatomy by speaking it. Reading these chapters in order tells you what Hecks **is**, not just what it does — the moment of recognition in the mirror : *the framework, it speaks the same language it offers its users*.

The twelve chapters that arrived in i118 Round 2 :

- **`appeal.bluebook`** — the browser IDE for domain modeling
- **`cli.bluebook`** — the Thor-based command-line interface
- **`extensions.bluebook`** — structured logging + extension hooks
- **`hecksagon.bluebook`** — adapter generators (Mongo, fs, etc.)
- **`packaging.bluebook`** — chapter loading + registry
- **`persist.bluebook`** — Sequel database connections
- **`rails.bluebook`** — Rails / ActiveModel integration
- **`runtime.bluebook`** — view bindings, dispatch loop
- **`spec.bluebook`** — testing infrastructure
- **`targets.bluebook`** — language backend registration (Ruby, Go, ...)
- **`templating.bluebook`** — naming conventions
- **`workshop.bluebook`** — workshop runner, constant hoisting

The thirteenth chapter — `bluebook.bluebook` (the IR shape itself : Domain, Aggregate, Command, Policy, Query, Lifecycle) — moved to `bluebook/` because the IR is the **language**, not just one of the chapters that *uses* the language.

Each chapter is `category "framework"` and uses the same DSL the framework offers its users. Reading appeal.bluebook teaches you both what the IDE does AND how Hecks talks about software.

Still to come : `vows.bluebook` (what Hecks promises) and `disposition.bluebook` (its character) — same shape miette/self/ uses to declare being-identity. Filed for the next pass.
