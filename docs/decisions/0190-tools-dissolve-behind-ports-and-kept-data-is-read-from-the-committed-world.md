# Tools dissolve behind ports, and kept data is read from the committed world

**Status:** Accepted. Date: 2026-11-08. Accepted by the owner (2026-11-08). Proposed 2026-11-07. Narrows [0154](0154-hand-written-code-is-a-kernel-an-adapter-or-a-projector.md):
it says where the hand-written code in `lib/hecks/tools` goes under that rule. Builds on
[0136](0136-hecks-defaults-to-memory-and-a-local-hecksagon-opts-in.md) (Memory unless the world opts in)
and [0163](0163-hecks-is-one-context-in-task-modules-and-a-bang-is-the-only-sign-of-a-write.md) (`audience`,
the `Run` kind). Narrows [0080](0080-bin-scripts-become-adapters-on-a-hecks-bluebook.md) ("bin scripts
become adapters") and settles the question [0102](0102-consolidate-bin-scripts-into-domain-driven-aggregates.md)
left open about `lib/hecks/tools`. Nothing here is built; the plan is in Consequences.

## Context

ADR 0080 turned every bin script into a command on a bluebook with its outside-world work in an
adapter. What it left behind is `lib/hecks/tools`: the script bodies, moved into the gem. ADR 0102
asked whether code with no domain boundary belongs in `lib/hecks/` or in a `lib/hecks/tools/`
directory "to signal no domain boundary", and did not answer. The directory answered by being
used, and it now has a shape of its own that no rule in the repository describes.

- **A tool is a script in a module.** It answers `main(argv, root:)`, is named in
  `Hecks::Tools::REGISTRY`, and is run by `Tools.script` (as a program's whole body) or `Tools.run`
  (from a checkout's root). It parses `ARGV` with `OptionParser`, prints to `$stdout` and returns an
  exit status.
- **A command reaches a tool by its printed text.** The adapter `RubyChild`
  (`lib/hecks/hecks/adapters/codebase/ruby_child.rb`) runs the tool in this process, captures what it
  printed with `ConsoleCapture`, and hands the string to the adapter that called it, which parses the
  string back into a value. Arguments go in as an argv list and results come out as text. The tool
  already runs in-process, so the capture and the parsing exist only to keep a script's calling
  convention.
- **Tooling is told apart from client data by a word.** The shape ledger skips "tooling bluebooks"
  (`ShapeLedger::Scope`, `lib/hecks/shape_ledger/scope.rb`): a bluebook is held when it is a
  framework member (`Framework.members`) or when its committed persistence is an era-managed
  adapter. Era and mint refusals, `disposable_ledger` and the placement of a check in the gate each
  ask a version of the same question in their own code.
- **The tools that matter most to a client are the ones the language cannot say.** Reattesting an
  era, backfilling projections, merging a tail, scaffolding and auditing a translation: all reach
  stored data, and all are built as tools called by string.

ADR 0154 gave the rule: a hand-written file is a kernel, an adapter behind a port, or a projector.
A tool is none of the three. It does I/O, so it is not a kernel; it writes nothing nobody edits, so
it is not a projector; and it sits behind no port. By that rule it is the finding.

## Decision

1. **No new construct: a tool is the adapter behind a hecksagon port that a `Run` aggregate calls.**
   The bluebook says what the work is: a `Run` command (ADR 0163 point 5) with its refusals as
   `given`s and its result as an event. The hecksagon declares the port. The code that does the work
   is the `.rb` behind the port's `.adapter` file, in the adapter folder of the domain it serves.
   Three constructs were considered to give tools a home and none is added: see Alternatives.

2. **Kept data is read from the committed world.** The line between data Hecks must protect and data
   it may drop is a single question, `kept?`, with no tag and no "tooling" word in code. A bluebook is
   kept when it is a framework member (`Framework.members`, which clients persist) or when its
   committed world names an era-managed store and does not mark it `disposable_ledger`. Everything
   else is disposable. The flag stays: the QA and fuzz ledgers keep `PostgresEra` and do without eras
   (ADR 0168), so an era-managed store is not by itself kept. A local `*.local.world` that opts a
   copy into SQLite or Postgres (ADR 0136) never makes data kept, because the rule reads the committed
   world only. The rule is declared once and exported in the IR, so the Rust host's refusals read the
   same answer as Ruby's. `ShapeLedger::Scope`, `disposable_ledger`, the era and mint refusals and the
   placement of a gate check call it; none keeps a rule of its own.

3. **`lib/hecks/tools` dissolves and `Hecks::Tools` goes.** Code with one caller moves into that
   caller's adapter folder. Code with several callers becomes a library module beside its subject
   (the comment-style checker beside the comments it checks, the deploy recipe lint beside deploy).
   The era tools are exempt from this step until step 6 has made them commands; they move then.

4. **A RuboCop cop keeps the shape from returning.** A custom cop refuses `OptionParser`, `ARGV`,
   `exit` and writes to `$stdout` outside adapters and the CLI entry. It starts with a baseline of the
   files that offend today, and the baseline only shrinks. It needs an entry in ADR 0091 or its own
   configuration file, skips `exe/` and the adapter folders, and applies to Hecks's own tree only.

5. **Plain calls in, values out.** A moved tool is a method that takes values and returns a value or
   raises. `REGISTRY`, `main(argv, root:)`, `Tools.script` and the `ConsoleCapture` swap around a tool
   are deleted, as are direct reads of `ENV` inside a tool; what a tool needs arrives as an argument
   or a setting. Callers that parsed a tool's printed text take the value instead. Progress a
   long-running adapter reports goes through `StageProgress`, not `$stdout`.

6. **Dead and spec-only tools are deleted.** A tool with no caller outside its own spec is removed
   with that spec. Era recovery is the exception, because it is needed and has no other home:
   reattesting an era, the projection backfill, the tail merge, and translation scaffolding and
   audit become commands on one era `Run` aggregate. `scaffold_translation` and `audit_translation`
   already exist as the `SchemaRevision` queries (the vocabulary rows name them); the work there is to
   remove the duplicate, not add a third. The audit writes era 1 when the lineage is empty, so the
   read and the write stay two commands. These commands keep the runtime overlay that ADR 0136
   gives the era tools, so a domain a local file opts into `PostgresEra` is seen as bound to it.
   Every caller of `RubyChild` is moved before the class is removed.

7. **Outside callers reach commands and nothing else.** The MCP door, the CLI, CI and client
   repositories call commands. `audience` (ADR 0163 point 4, not a `for:` key) says who a command is
   for. A refusal names its remedy as a command reference, and a check confirms every reference
   resolves to a command that exists. The check scans Ruby refusals and the Rust host's refusal
   strings, and runs in the quick gate.

8. **`kept?` applies in every app; the cop and the layout are Hecks's own.** A client's bluebooks are
   judged by the same rule, so a client's disposable ledger is recognised by the same word. The
   folder layout and the cop describe this repository's code and are not asked of a client.

## Alternatives considered

- **Reuse ADR 0119 `provides`.** A package declares a capability and names the command, port
  operation, mark or attribute that supplies it, and that is close to "this adapter does this work".
  It is not extended here. `provides` is read by the Rust host from `ir.json` (`provides.<name>`,
  and `adapter_provides` in `rust/host/core/src/ir.rs`), so it is part of what a host and its package
  agree on at runtime. A tool is a development-time collaborator of the Ruby side. Putting tools in
  `provides` would widen a contract the host reads, to describe code the host never runs.
- **A `capability` construct.** A language construct for "a thing Hecks can do for you". ADR 0119
  declined the same construct for the same reason: Ruby and Rust parser work for a reader that does
  not need it. A port and its adapter already say it.
- **A `tool` construct.** It would give the directory a name in the language. It would also confirm
  that a tool is a thing apart from a command and its adapter, which is the confusion this ADR
  removes.
- **Tag tooling bluebooks.** A `tooling true` mark on a bluebook, or a `Tooling` aggregate list,
  would be easy to read. It repeats what the committed world already says and drifts from it. The
  rule reads the world, so the world cannot disagree.
- **Treat any era-managed store as kept.** Simpler, and wrong for the ledgers that use `PostgresEra`
  without eras: they would need an era for every shape change, which `disposable_ledger` exists to
  avoid.
- **Keep `lib/hecks/tools` and rename it.** The directory is the symptom. Renaming keeps the script
  convention and the text round trip.

## Consequences

- One rule answers "is this data kept", in Ruby and in Rust. A shape change to a kept store needs an
  era or an edge; a disposable one does not. The word "tooling" leaves the code and the messages of
  the shape ledger.
- A client that holds a `disposable_ledger` store keeps its behaviour, since the flag stays. A client
  whose committed world names an era-managed store without the flag is kept, as before. A client that
  relied on a local overlay to make a store kept was never kept by this rule; it declares the store in
  its committed world. This is a migration note for the holders of `disposable_ledger`, not a change
  to their data.
- The calling convention between adapters and their work becomes a method call. The text a tool
  printed stops being an interface, so a change to a report's wording no longer breaks a caller.
- A refusal always points at a command a person or an agent can run, and a stale pointer fails a
  gate instead of surfacing as a refusal nobody can follow.
- The cop leaves a baseline file the work shrinks to nothing. Until it is empty, the cop's own rule is
  advisory for the files in it.
- Plan, as ordered Work rows: (1) the `kept?` rule, exported in the IR and called by its five
  callers; (2) the cop and its baseline; (3) deletion of dead and spec-only tools; (4) the era `Run`
  aggregate and the remedy check; (5) the per-family moves into adapter folders and library modules;
  (6) deletion of `REGISTRY`, `RubyChild`, `ConsoleCapture` where unused, and the folder.
