# Hecks distills to a core that no satellite is needed to build

**Status:** Proposed. Date: 2026-10-30. Not built: 7.0.0 and 7.1.0 have shipped and neither CHANGELOG entry nor `packages/` carries the split.
Planned for 7.0.0 when written. Meets [ADR 0163](0163-hecks-is-one-context-in-task-modules-and-a-bang-is-the-only-sign-of-a-write.md)
where the Hecks context is classified by module.

## Context

The repository holds the language, its Ruby reference toolchain, a Rust runtime, and every tool
that grew around them: deploy, the site, CI modelling, tickets, the composer, the Rails bridge,
framework bluebooks a domain can attach. Nothing says which of these the language needs and which
need the language, so a change to a deploy recipe and a change to the grammar ride in one gem, one
suite and one release.

Each `*.bluebook` under `lib/hecks/` declares one bounded context with `Hecks.bluebook "<Name>"`,
and several files can declare the same one. The contexts declared today:

| Context | Files under `lib/hecks/` | Aggregates |
|---|---|---|
| Bluebook | `language/bluebook/*.bluebook` | Bluebook, Aggregate, Command, Entity, Policy, ProcessManager, ReadModel, Query, ValueObject, Syntax, Vocabulary |
| Paging | `language/bluebook/attaches/paging.bluebook` | Syntax |
| Sentence | `language/sentence/` | Phrase |
| Expression | `grammar/expression.bluebook` | Operator, Normalisation, Expression |
| Hecksagon | `language/hecksagon/` | Hecksagon, DomainPort, PortOperation, AdapterBinding |
| Port, Adapter | `language/port.bluebook`, `language/adapter.bluebook` | Port; Adapter |
| World | `language/world/` | World, Wiring |
| ContextMap | `language/context_map/` | ContextMap |
| Translation | `language/translation/` and `grammar/translation.bluebook` | TranslationAggregate, Translation; Rule, Map |
| Hecks | `hecks/*.bluebook` | the toolchain's own domain, in ADR 0163's modules |
| Change, Compliance, ConsoleSettings, Governance, Identity, Privacy | `framework/bluebook/` | framework members a domain attaches |
| Tenancy | `tenancy/bluebook/` | Tenant |
| Deploy | `deploy/bluebook/` | targets, rolls, recipes, checks, Tenant |
| Site | `site/bluebook/` | Route, SiteProjection |
| RailsApp | `rails_app/bluebook/` | App, Listing |
| Composer | `composer/bluebook/` | Draft |
| Bulk | `bulk/bluebook/` | BulkRun |
| SME | `sme/bluebook/` | Interview |
| Tickets | `tickets/bluebook/` | Finding, Adr, Work |
| QualityControl | `quality_control/` | Target, Sweep, Bug, Angle, Ticket, Patch, DailyQuota, Improvement, Clearance |
| CiPipeline | `ci_pipeline/` | Workflow, JobSpec, Job, Build, Corpus |
| CiSpeed | `ci_speed/` | Run, Budget, Lever, Experiment, Finding |
| CiWorkflows | `ci_workflows/` | Pipeline |

There is no standalone IR schema file. The IR's shape is what the Bluebook context's aggregates
declare, frozen as `spec/golden/ir/Bluebook.json` by `spec/ir_golden_spec.rb`. The corpus is every
domain `Hecks::Corpus` names and the goldens under `spec/golden/ir/`.

## Decision

1. **The core is the language spec and what keeps it.** The spec is three things: the grammar
   (the Bluebook, Paging, Sentence and Expression contexts, and the Hecksagon, Port, Adapter,
   World and ContextMap contexts that a domain's wiring is written in), the IR schema (the
   Bluebook context's aggregates as frozen in the golden IR), and the conformance corpus (the
   corpus domains and their goldens). The core also holds the commands that change, project and
   check the spec.

2. **The core never depends on a satellite.** A core file requires no satellite file, names no
   satellite aggregate, and calls no satellite adapter. A satellite depends on the core and on
   nothing that depends on it in turn. Where the runtime needs a satellite's behaviour, it reaches
   it through a declared capability, as it already reaches Identity, Privacy and Governance today:
   the capability is core, the bluebook that provides it is not.

3. **Contexts first, then technology.** The line is drawn between bounded contexts, and only then
   between languages. Rust is an implementation of the language, not a context of its own. The
   Rust runtime under `rust/` becomes the satellite `hecks-rust`, which must pass the corpus.

4. **Ruby keeps the name `hecks`** and stays the reference toolchain. Until the end point in
   decision 6 it is also the bootstrap oracle: `GOLDEN=rewrite` on `spec/ir_golden_spec.rb`
   regenerates the goldens from what Ruby produces.

5. **The projection interface is core; a concrete projection is core only if the core's own build
   calls it.** `Projector` and `ProjectionFiles` are core. A projection whose output the core
   reads back to build or check itself is core. A projection that writes another implementation's
   tables, a workflow file or an app's files is a satellite's, even when its source rows are core.
   `ReadModel` is a language aggregate, a query shape a domain declares, and is core; it is not
   part of the output-projection machinery.

6. **The corpus takes over from Ruby at a milestone.** Ruby stops being the oracle on the first
   release in which all three hold:
   - `hecks-rust` passes the whole corpus with no case excused for it;
   - every admitted Syntax row has a corpus case whose golden exercises it;
   - `ConformanceRun` can check a golden against any implementation without Ruby producing the
     expected side.

   From that release a golden changes only by an edit to the corpus admitted through
   `LanguageRun`, `GOLDEN=rewrite` is retired, and a disagreement between Ruby and a golden is a
   bug in Ruby.

### Core

- The Bluebook context, `ReadModel` included.
- Paging, which attaches its rows to the core grammar table and is read by the query interpreter.
- Sentence and Expression, whose rows feed the parser and the expression tables.
- Hecksagon, Port, Adapter, World and ContextMap, the language a domain's wiring is written in.
- The corpus and the golden IR.
- From the Hecks context, by ADR 0163 module:
  - `evolve`: `LanguageRun` and `SyntaxBootCache`. The language's own changes and the boot cache
    of its grammar.
  - `check`: `ConformanceRun` and `ModelCheckRun`. They hold the spec against itself and against
    an implementation.
  - `test`: `TestSuiteRun`, which runs the gates a grammar edit must pass.
  - `build`: `CorpusRun`, which reads the corpus and the IR.

The projections the core's own build calls, all `LanguageRun` commands in `evolve`:

| Command | Writes |
|---|---|
| `ProjectModel` | the Bluebook model's holding half under `lib/hecks/bluebook/` |
| `ProjectVocabulary` | `lib/hecks/vocabulary.rb` |
| `ProjectBootstrapTable` | the DSL's bootstrap fallbacks |
| `ProjectExpressionTables` | the expression operator and normalisation tables |
| `ProjectReference` | the DSL reference that `ConformanceRun` checks against the language |

### Satellites

- `hecks-rust`: everything under `rust/`, and the projections that write it. These are
  `LanguageRun`'s `ProjectRustVocabulary` (and its second name `ProjectRefusalWording`),
  `ProjectReservedNames`, `ProjectParserTable`, `ProjectPhraseTable` and `ProjectFieldHints`;
  `KernelRun` and its `ProjectKernelCapabilities`; `Build` and its `ProjectRust` and `build_*`
  family; `RegenerationRun`'s corpus regeneration; and `Host`. Their source rows are core and the
  satellite reads them; the files they write are the satellite's.
- The framework members: Change, Compliance, ConsoleSettings, Governance, Identity, Privacy.
- The era machinery: the Translation context, and from Hecks the `migrate` module (`Era`, `Seal`,
  `RehearsalRun`) and `Audit`, which walks a seal's chain.
- Tenancy, Deploy, Site, RailsApp, Composer, Bulk and SME.
- Tickets and QualityControl.
- CiPipeline, CiSpeed and CiWorkflows, with `RegenerationRun`'s `ProjectCiGates`,
  `ProjectCiPipeline`, `ProjectLanes` and `ProjectToolsDoc`.
- From the Hecks context, the rest of each module the core draws on, and these modules whole:
  `operate`, `deliver`, `release`, `start` (`ProjectCli`, `ProjectRails`), `serve`, `find`,
  `delegate`. In `check`: `GateRun`, `StyleRun`, `InspectionRun`. In `test`: `FuzzRun`, once
  `fuzz_conformance` has moved to `ConformanceRun`. In `evolve`: `CodemodRun` and `ScriptRun`.

### Where this meets ADR 0163

ADR 0163 settles that every file under `lib/hecks/hecks/` is one context, grouped in modules. This
record does not split it. The core line runs through four modules (`evolve`, `check`, `test`,
`build`) by aggregate, and is held there as a dependency rule: a core aggregate's commands,
policies and adapters name no satellite aggregate of the same context. The other modules are
satellite as a whole.

ADR 0163's collapsed families put core and satellite values behind one command:
`RegenerationRun.project! what=` carries `vocabulary` and `parser_table` alike, and
`Build.build! target=` is satellite throughout. Each value is bound to its own port operation in
the hecksagon, so the core holds the command and its core values, and a satellite binds its own
values in its own hecksagon.

## Open questions

- **`Tenant`** is declared by Deploy (one tenant's realm and schema as a deploy provisions it) and
  by Tenancy (a tenant's durable identity and lifecycle). Proposed: Tenancy keeps `Tenant`, and
  Deploy's becomes `TenantProvisioning`, which refers to a Tenancy `Tenant` by id.
- **`Build`** is declared by CiPipeline (one CI run of one commit) and by Hecks (one build of a
  domain for the Rust host). ADR 0163 keeps Hecks's `Build` in the `build` module and renames
  `Commit`, `Checkout`, `PullRequest` and `PushTrain`, but not `Build`. Proposed: CiPipeline's
  becomes `CiRun`, which matches what it records; Hecks's `Build` moves with `hecks-rust`.
- **`Finding`** is declared by CiSpeed (a way CI loses time) and by Tickets (one thing observed
  about Hecks). Proposed: Tickets keeps `Finding`; CiSpeed's becomes `Slowdown`.
- **`Syntax`** is declared by the Bluebook context (the grammar table) and by Paging (the rows it
  contributes). Paging's is the attach shape ADR 0026 describes, so the same name is the point.
  Proposed: keep both, and say in the language that an attaching sub-language's `Syntax` is the
  contribution to the core's table. If the name must differ, Paging's becomes `SyntaxRows`.
- **`Translation`** is declared by `language/translation/` (an edge between two eras) and by
  `grammar/translation.bluebook` (the rules a value survives a shape change by). The framework
  index globs only the first; the second is loaded by its specs. Proposed: the second becomes
  `TranslationRules`. Both leave the core with the era machinery.
- **`Change`** is a framework member today, and ADR 0163 renames Hecks's `Commit` to `Change`. They
  are different contexts, so the IR does not collide, but a reader of `Change` must now ask which.
  Proposed: decide before ADR 0163's renames land.
- **`Run`** is CiSpeed's aggregate and the aggregate kind ADR 0163 introduces. Proposed: CiSpeed's
  becomes `CiTiming` with the other CiSpeed names.
- **`operate`.** `Operation` and `Introspection` record what the Ruby runtime does, and the core's
  build does not call them, so they are satellite here. If the Ruby runtime stays inside the core
  after the end point in decision 6, they may move into it.
- **A module across two gems.** ADR 0163 makes the Hecks context one bluebook. While its satellite
  modules ship in the `hecks` gem the line is a rule, not a package. Whether a satellite module
  can ship from another gem and still load into the one `"Hecks"` bluebook is open.

## Consequences

- A change to a satellite cannot break the core's build, and the core's suite can run without
  `rust/`, the deploy tooling or the CI models.
- `hecks-rust` is checked the way any implementation will be: by the corpus.
- The projections that write Rust move their output with `hecks-rust`; their source rows stay in
  the core, and the satellite runs them against the core it pins.
- The capability names the runtime reaches framework members by become part of the core's
  surface, and a client pins them with the language.
- The changes this record implies ride 7.0.0 alongside ADR 0163's change: `hecks-rust` becomes a
  satellite, the Rust projections move their output with it, and the renames proposed under the
  open questions, if taken, land in the same era as ADR 0163's renames.
