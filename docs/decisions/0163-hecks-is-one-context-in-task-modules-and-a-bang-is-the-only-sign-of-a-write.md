# Hecks is one context in task modules, and a bang is the only sign of a write

**Status:** Proposed. Date: 2026-10-30. Supersedes [ADR 0096](0096-hecks-bluebooks-sit-in-four-modules.md).
Planned for 7.0.0.

## Context

Bare `hecks` in a checkout prints every command and query of the Hecks domain as one wall. The
listing is a projection (`Projector::CliProjector`), so the wall is the model's shape shown back:

- **One bluebook in many files.** Every file under `lib/hecks/hecks/` declares
  `Hecks.bluebook "Hecks"`, so the IR holds one bluebook and the launcher one flat list. The file
  lines are arbitrary: `codebase.bluebook` holds `PublishingRun` and `PromotionRun`, which are
  release work; `custodian.bluebook` holds delivery, journal upkeep and operations side by side.
- **Grouped by record, not by task.** Each heading is an aggregate, so one task spreads across
  many headings. Projections sit under `LanguageRun`, `KernelRun`, `RegenerationRun`, `Build`,
  `Launch` and `Introspection`; checks under `ConformanceRun`, `KernelRun`, `Build`,
  `ModelCheckRun`, `GateRun`, `StyleRun` and `Audit`; servers under `CorpusRun` and `Launch`.
- **Names that mislead.** `Release.tag!`, `mark_published!` and `verify!` only record; the tagging
  is `PublishingRun.publish!`. `SyntaxBootCache.rebuild!` records a rebuild. The Ruby-against-Rust
  conformance checks sit under `Build`. `InspectionRun` says flog and reek and holds `search`.
- **Bookkeeping is guessed.** A command is internal when its role is `System`
  (`lib/hecks/projector/cli_projector/command_specs.rb`), so a record-only verb whose role is not
  `System` is listed as an action.
- **Families spelled as separate commands.** The `project_*` verbs, the `build_*` verbs, the spec
  runners, the style checks and the language row moves are each one act on different targets.
- **Adapter words in domain names.** `PullRequest`, `Commit`, `Checkout`, `PushTrain`, and verbs
  like `squash`, `push` and `log`, name what git and GitHub do.
- **No bang does not mean read.** A name without `!` reaches a command when one matches
  (`lib/hecks/adapters/driving/cli_runner/resolution.rb`), so `style_run.check_comments` runs a
  command while looking like a read. `query` exists only to settle a name a command and a query
  share.
- **Two command lines.** `Hecks::CLI` repeats part of the launcher (`run`, `docs`, `narrate`, `ir`,
  `stores`, `model_check`, `smoke_test`, `project_diagrams`, `project_cli`, `mcp`) in positional
  forms, the `legacy` list of the world's `launcher` setting.

ADR 0096 named four modules (Language, Runtime, Operations, Maintenance) that group whole
bluebooks. It was never built or checked, and it put the line between maintaining Hecks and
operating a domain into a grouping, where an audience says it better.

## Decision

1. **The Hecks domain is one bounded context, grouped in DDD modules.** Its aggregates share one
   language, so the trouble is grouping, not boundaries. A module is a block inside the one
   `"Hecks"` bluebook, and each module is a folder:

   ```ruby
   Hecks.bluebook "Hecks" do
     module "Deliver" do
       vision "Take finished work into the shared line."
       aggregate "Landing" do
         # …
       end
     end
   end
   ```

   Aggregates keep their constants and stored shapes when they move into a module; the context
   map is unchanged. `module` means only this: a grouping inside one bluebook.

2. **A folder means one thing.** `lib/hecks/hecks/<module>/` holds that module's `.bluebook`.
   `hecks.bluebook` opens the context and declares nothing else; `hecks.hecksagon`, the worlds,
   `translations/` and the behaviors stay at the top. Every adapter stays in
   `lib/hecks/hecks/adapters/`: declarations are grouped by task, the imperative side lives in one
   place, and the hecksagons say which module uses which adapter.

3. **A module is the task a person comes to do.** An aggregate whose commands serve two tasks is
   split. The modules, named as verbs so `hecks <module>` reads as the task:

   | Module | The task | Aggregates |
   |---|---|---|
   | `operate` | Run a domain and look inside it | Operation, Host, Introspection |
   | `check` | Is it right? | GateRun, ModelCheckRun, ConformanceRun, StyleRun, InspectionRun, Audit |
   | `test` | Run the specs and fuzzers | TestSuiteRun, FuzzRun |
   | `build` | Compile and regenerate | Build, RegenerationRun, KernelRun, CorpusRun |
   | `deliver` | Take finished work into the shared line | Workspace, Change, Landing, SendTrain, Shipment, ReviewRequest |
   | `release` | Certify, publish, pin | Release, PublishingRun, PromotionRun, Registry, Package |
   | `migrate` | Move a store between shapes | Era, Seal, RehearsalRun |
   | `evolve` | Change the language and rewrite to match | LanguageRun, SyntaxBootCache, CodemodRun, ScriptRun |
   | `start` | Begin a domain or a project | Launch |
   | `serve` | Open something on a port or stdio | Server |
   | `find` | Read the code | Codebase |
   | `delegate` | Hand work to a background session | AgentRun |

   The splits: `Server` is new and takes `present`, `compose`, `preview` and the IR MCP server from
   `CorpusRun` and `serve_mcp` from `Launch`. `Codebase` is new and takes `search`,
   `read_source`, `outline` and `declaration` from `InspectionRun`. `check_conformance` and
   `fuzz_conformance` move from `Build` to `ConformanceRun`; `clear_caches` moves from
   `TestSuiteRun` to `Build`.

4. **Who a command is for is declared.** A command says `for :person`, `:agent`, `:ci` or
   `:record`, one or several; it defaults to `:person, :agent`. `for:` decides listing only; `role`
   still decides who may issue it. Bare `hecks` lists `:person`, the MCP door lists `:agent`, and
   `:ci` and `:record` are listed only by `--all`. The world's `maintainer` setting names modules
   (`evolve`, `release`) instead of aggregates, so a client project never lists how Hecks
   maintains itself; this is where ADR 0096's maintenance line now lives.

5. **A run is a declared kind.** The `*Run` aggregates repeat one lifecycle, one set of bookkeeping
   commands (`accept`, `perform`, `complete`, `fault`, `examine`) and one pair of queries. An
   aggregate declared `kind: "Run"` gets them once, marked `for :record`.

6. **A bang is the only sign of a write.** `Name!` dispatches a command and `Name` asks a query,
   in every spelling, the verb form included (`Hecks::Landing.Land!`). A command named without
   `!` is refused with the `!` spelling as a hint. `query` stays as an old spelling and leaves the
   listing and the docs.

7. **A family is one command with an argument** where the verbs are one act on different targets:
   `Build.build! target=`, `RegenerationRun.project! what=`, `TestSuiteRun.run!` with `file=`,
   `example=` or `since=`, `StyleRun.check! lang=` and `StyleRun.fix! lang=`, and
   `LanguageRun.move! row= to=`. Each value is bound to its own port operation in the hecksagon,
   so no hand-written dispatch stands behind the command. `--help target=wasm` prints that
   value's own refusals, and the MCP schema lists the values.

8. **Domain names carry no adapter words.** `PullRequest` becomes `ReviewRequest`, `Commit`
   becomes `Change`, `Checkout` becomes `Workspace`, `PushTrain` becomes `SendTrain`; the verbs
   `squash` and `merge` become `take`, `push` becomes `send`, and `log` becomes `history`. An
   aggregate's `formerly_known_as` resolves the old name until 8.0. Once the renames land,
   `model_check` refuses a module, aggregate or command named after a port or adapter the
   hecksagon names.

9. **One command line.** `Hecks::CLI`'s table and the world's `legacy` list are retired. Short
   spellings come from the world's `names` and follow the bang rule (`hecks run!`, `hecks docs`,
   `hecks mcp!`).

10. **One era.** Every shape change of 7.0.0 (the new aggregates, the moved commands, the
    renames, the collapsed families) lands as one era. `RehearsalRun.request!` runs it against a
    copy of the push train's data, and must say the mint goes through, before the push.

## What the language needs

- A `module` block in the Bluebook language, admitted through `LanguageRun` (`propose`, then
  `admit`), and a loader that reads one bluebook from its module folders.
- `formerly_known_as` on an aggregate; the bluebook has it today.
- `for:` on a command.
- `kind:` on an aggregate, and the `Run` kind. A kind is a text in the bluebook's own words,
  `lib/hecks/language/kinds/<kind>.kind`, evaluated around the aggregate's body with the aggregate's
  name and stem filled in; `aggregate` admits `kind:` as an argument row, and the built IR is the
  one the hand-written aggregate had. The Run kind covers the seven codebase runs whose lifecycle,
  bookkeeping commands, queries and policies match word for word (`LanguageRun`, `KernelRun`,
  `ConformanceRun`, `RegenerationRun`, `CodemodRun`, `TestSuiteRun`, `CorpusRun`); `GateRun`,
  `StyleRun`, `InspectionRun` and `ScriptRun` differ in the wording of their bookkeeping goals,
  and the runs of other modules differ in lifecycle.
- A command attribute whose closed set of values binds each value to a port operation.
- The adapter-word check in `model_check`.

## Plan

0. **Planned work in the Tickets bluebook.** Tickets holds `Finding` and `Adr`; a plan step is
   neither. Add a `Work` aggregate (planned, started, done, linked to an `Adr`) and record this
   plan's steps through the push train's copy, which persists them. Until then this list is the
   plan.
1. **`everyday` in the world's `launcher` setting**, listed first inside a checkout too. Data only.
2. **`for:`**, and the record-only verbs marked `:record`.
3. **`kind: "Run"`.**
4. **`module`**, and the loader reading module folders. The aggregates move into their folders
   with no shape change.
5. **The 7.0.0 change**, one diff and one era: `Server` and `Codebase`, the moved commands, the
   collapsed families, the renames, the bang rule (a codemod adds `!` to every caller in the
   repository: hooks, workflows, the Guardfile, docs and specs), and the retired `Hecks::CLI`
   table. Rehearsed against a copy of the train's data before the push.
6. **The adapter-word check** joins the gate, green from its first run.

## Consequences

- Bare `hecks` fits on a screen; `hecks <module>` lists one task, commands and queries together,
  each line the call to type.
- The modules move no stored data; the 7.0.0 change mints one era on the push train.
- Client projects pin a hecks version, so the bang rule, the renames and the retired positional
  forms reach them when they move to 7.0.0. Their callers are few: `bin/host`, a Makefile, a
  Dockerfile and a CI workflow each.
- `CLAUDE.md`, the hooks and the notes that name commands change once, in 7.0.0.
- ADR 0096's file-header comments ("in the Operations module (ADR 0096)") go with the files they
  head when the modules move.
