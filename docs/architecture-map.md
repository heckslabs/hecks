# The library

<!-- prose anchor="The library" purpose="concept" supports="code_file:lib/hecks/language code_file:lib/hecks/grammar code_file:lib/hecks/bluebook code_file:lib/hecks/runtime code_file:lib/hecks/adapters/driven code_file:lib/hecks/adapters/driving code_file:lib/hecks/ports code_file:lib/hecks/ports/persistence/plugins/era code_file:lib/hecks/projector code_file:lib/hecks/router code_file:lib/hecks/query_specification code_file:lib/hecks/projections code_file:lib/hecks/forms code_file:lib/hecks/fuzzing code_file:lib/hecks/doc code_file:lib/hecks/framework code_file:lib/hecks/deploy code_file:lib/hecks/language/translation" -->
```ruby skip
lib/hecks/
  language/     the language, declared in its own bluebooks.  WHAT A BLUEBOOK IS.
  grammar/      the expression and translation sublanguages, and the Admit gate.
  bluebook/     dsl → ir → expression.  READING ONE.
  runtime/      dispatch, instances, the registry.  RUNNING IT.
  adapters/     driven adapters — persistence, authentication, clock, identity, and the rest (lib/hecks/adapters/driven/).
  ports/persistence/plugins/era/  domain-version translation — eras and lineage.
  projector/    IR serialization — the translation-edge digest reads it.

  adapters/driving/   the driving adapters (Ruby, CLI, MCP, JSON, webhook).  Class-free, per boot.
  router/               project-wide dispatch; installs each bluebook's namespace at boot.
  ports/                domain ports — auth, identity, persistence, query.
  query_specification/  a query's shape, held apart from any engine that answers it.
  projections/          IR as a capability — emits_ir and its consumers (OIDC, reference, parser table).
  forms/                IR → HTML, content-negotiated against plain JSON.
  fuzzing/              generated sequences, checked against declared properties.
  doc/                  the generated DSL reference (hecks language_run.project_reference).
  framework/            shared, domain-agnostic bluebooks — e.g. Governance, Identity, Privacy.
  deploy/               the Deploy bluebook — what deployed_to means.
```

Domain-version translation (eras and lineage) lives under `language/translation/`. This
map names the main layers only; `ls lib/hecks` is the full list.

The split follows the dependency direction, not the topic: the
expression evaluator lives in the semantic core, not `projector/`,
because the runtime evaluates every `given` and invariant through it
directly. Nothing here is required by `require "hecks"` unless a
booted domain uses it — `forms/` and `fuzzing/` stay out of the core
boot chain, so a project that never touches one never pays for it.

## The second runtime

<!-- prose anchor="The second runtime" purpose="concept" supports="code_file:rust/src/kernel code_file:rust/host code_file:rust/lsp code_file:rust/build code_file:rust/src/generated code_file:rust/parser code_file:rust/codegen code_file:rust/web doc:docs/implemented/guides/projections.md doc:docs/implemented/rust-host.md" -->
```ruby skip
rust/
  src/kernel/     the hand-written interpreter — walks given/ensures/mutation data, same job as CommandInterpreter#call in Ruby.
  host/           the production HTTP host (hand-written): serves the domain's WASI module over Postgres, mints eras. See implemented/rust-host.md.
  lsp/            the language server.
  build/          the Rust build tooling the build commands call.
  src/generated/  typed structs and enums per domain, written by hecks build.project_rust — never hand-edited.
  parser/         a generated Rust parser, built from the language's own Syntax bluebook (hecks language_run.project_parser_table).
  codegen/        the Rust code generator itself, driven from canonical IR; hecks build.project_rust builds the IR from the live registry and runs it.
  web/            the wasm-bindgen crate hecks build.build_browser_wasm builds — a separate cdylib from the WASI binary.
```

`rust/src/kernel/` and `rust/host/` are written by hand — everything
else (`generated/`, the parser tables, the type shapes) is projected
from the same canonical IR the Ruby runtime reads. See [Projections: Rust and
WebAssembly](implemented/guides/projections.md) for what
that buys, and [Running a
runtime](implemented/guides/running-a-runtime.md) for the
field-by-field contract a third dispatch runtime would need.

## The bluebooks

<!-- prose anchor="The bluebooks" purpose="concept" supports="code_file:lib/hecks/doc/regions/bluebook_map.rb" -->
The trees above are code: the language, the runtimes and the adapters behind the ports. What the library
declares as model is its bluebooks, each kept beside the code that answers it. Each line names a bluebook, the
directories its files sit in, and the vision it declares, written from the files by
`hecks language_run.project_reference!`.

<!-- generated:begin id=bluebooks -->
- **Agents** (`lib/hecks/agents/`): Each agent role does one judgment step and talks to the others only through events; no role may take an owner decision.
- **Bulk** (`lib/hecks/bulk/bluebook/`): Send one command to every row a query answers, and keep what each row did with it.
- **Catcher** (`lib/hecks/catcher/`): Raw actions seen outside any declared command are kept, judged, and either brought under a declared command or dismissed.
- **CiPipeline** (`lib/hecks/ci_pipeline/`): A workflow file is what its rows say: a job runs after what it needs, a skipped gate leaves its dependents runnable, a build passes only when every required job settled, and a corpus is regenerated once and shared.
- **CiSpeed** (`lib/hecks/ci_speed/`): A main CI run is measured as it finished, and a change to the pipeline is kept only when a run of the same cache state proves it faster.
- **CiWorkflows** (`lib/hecks/ci_workflows/`): Hecks's own GitHub Actions workflows, declared once as rows and projected into .github/workflows.
- **Coach** (`lib/hecks/coach/`): Miette coaches the crew from evidence: what she saw comes before what she advises, her words are relayed as hers, and what touches one of her vows is the owner's to decide.
- **Coder** (`lib/hecks/coder/`): Every bug QA logs is worked by one coder at a time, and a bug that cannot be fixed yet is still never hidden: it is stubbed, named, and retired once the fix lands.
- **Composer** (`lib/hecks/composer/bluebook/`): Write a bluebook in an editor and watch the domain draw itself, with an agent that can change the draft when asked.
- **Deploy** (`lib/hecks/deploy/bluebook/`): Generate, check and compare deploy recipes, project OIDC manifests and provision tenants.
- **Docs** (`lib/hecks/docs/`): A documentation page is made of regions, each projected from a bluebook, doctested by a booted example, or prose, and only a live page is held to its sources.
- **Fixer** (`lib/hecks/fixer/`): A logged bug gets one attempt at a time, each claimed, investigated, fixed and verified on the record, and the bug itself is only ever written by the quality ledger.
- **Change** (`lib/hecks/framework/bluebook/`): A change you can preview: it is planned, shown, confirmed against exactly that plan, and only then carried out, whatever script it runs.
- **Compliance** (`lib/hecks/framework/bluebook/`): Something elsewhere already acted to contain a risk; this domain tracks the human review that decides what happens next.
- **ConsoleSettings** (`lib/hecks/framework/bluebook/`): A generic admin console's own curated UI facts — nav, columns, state tones, which rows a detail panel shows — as real dispatched data instead of a hand-rewritten YAML file. A UI opinion the DOMAIN it's pointed at has no way to answer, never a business record; see the console app's own presentation_config.rb for the fuller story.
- **EventDelivery** (`lib/hecks/framework/bluebook/`): An event committed is owed to each of its consumers until each has answered it once.
- **Governance** (`lib/hecks/framework/bluebook/`): Organizational authority is explicit, reviewable, and historically explainable.
- **Identity** (`lib/hecks/framework/bluebook/`): Authentication proves an identifier; the organization decides what that identity means.
- **Privacy** (`lib/hecks/framework/bluebook/`): Which fields of a domain's own aggregates are sensitive is a fact about that domain, declared apart from it — the domain itself never spells out that one of its own attributes is PII or PHI.
- **Gate** (`lib/hecks/gate/`): A commit is green only when every quick-gate check passed on it, and a red verdict names the first check that failed.
- **Expression** (`lib/hecks/grammar/`): The subset of regular Ruby a predicate is allowed to be — small enough that every target can evaluate it, and carried as canonical text so no two readers can disagree about what was said.
- **Translation** (`lib/hecks/grammar/`, `lib/hecks/language/translation/`): The declared bridge from one era of a domain's storage shape to the next — every rule checkable, every loss written down, carried as one edge file.
- **Hecks** (`lib/hecks/hecks/`, `lib/hecks/hecks/build/`, `lib/hecks/hecks/catcher_care/`, `lib/hecks/hecks/check/`, `lib/hecks/hecks/ci_record/`, `lib/hecks/hecks/delegate/`, `lib/hecks/hecks/deliver/`, `lib/hecks/hecks/disk_space/`, `lib/hecks/hecks/evolve/`, `lib/hecks/hecks/find/`, `lib/hecks/hecks/github_events/`, `lib/hecks/hecks/ledger_care/`, `lib/hecks/hecks/migrate/`, `lib/hecks/hecks/operate/`, `lib/hecks/hecks/quiesce/`, `lib/hecks/hecks/redflag/`, `lib/hecks/hecks/rehearse/`, `lib/hecks/hecks/release/`, `lib/hecks/hecks/serve/`, `lib/hecks/hecks/stall_watch/`, `lib/hecks/hecks/start/`, `lib/hecks/hecks/test/`, `lib/hecks/hecks/tune/`): Compile and regenerate.
- **Interviews** (`lib/hecks/interviews/`): Work begins in a conversation: an interview keeps every exchange, and the Points the participants proposed, accepted, rejected or superseded, so whatever follows can cite where it came from.
- **Adapter** (`lib/hecks/language/`): The .adapter language, declared in itself. An adapter is a real, swappable implementation of one resource port — Memory, Postgres, Sqlite, and the rest — naming which fields (and which secrets) a world's own wiring for it must supply.
- **Port** (`lib/hecks/language/`): The .port language, declared in itself. A port names one resource a domain's own aggregates call by verb — persisted_by, posted_by, whatever a bluebook spells — bound to a real driven adapter at the world level. A sibling artifact to the bluebook, not part of one: the same port name is reused across every domain that needs the same kind of entry point.
- **Bluebook** (`lib/hecks/language/bluebook/`): The bluebook language, declared in itself. Loading a domain becomes dispatching commands into this meta-domain ; the IR it stores must equal the IR the DSL builder produces. The floor that stays hand-written is the interpreter — evaluating a predicate held as data — and IO.
- **Paging** (`lib/hecks/language/bluebook/attaches/`): The four words a page of results is read through — limit, offset, cursor, nulls — held as their own sub-language rather than as four more rows in the core's own grammar table. ADR 0026's own worked example: the core grammar does not name its extension points, so this bluebook names ITSELF onto them, with `attaches_to`.
- **ContextMap** (`lib/hecks/language/context_map/`)
- **Hecksagon** (`lib/hecks/language/hecksagon/`)
- **Sentence** (`lib/hecks/language/sentence/`): The plain sentences a business author writes in a .bluebook, declared as data. Each phrase is one row; the Rust parser's sentence front end is generated from them, so what an author may say is a table, not code.
- **World** (`lib/hecks/language/world/`)
- **LiveDiscovery** (`lib/hecks/live_discovery/`): A discovery call is consented before it is captured, keeps its turns as they were said, and shows the client only what the owner sends.
- **Pipeline** (`lib/hecks/pipeline/`): Every change is one passage, from the Work item that planned it to the release that shipped it, and where each one stands is a fact the pipeline itself holds.
- **PipelineBoard** (`lib/hecks/pipeline_board/`): The pipeline from a Work item to a release is read live, stage by stage, and shown with the real events it emitted.
- **Protocols** (`lib/hecks/protocols/`): A role proposes a working agreement; the roles it affects settle it by a quick yes or a veto with a reason; an accepted agreement is recorded and a peer flags a break for the retrospective.
- **QualityControl** (`lib/hecks/quality_control/`): A user should never be made to feel stupid by something that took what they said and quietly did otherwise. Every check writes down what it expected before it looks, every bug carries the test that proves it, and nothing reaches the outside world that nobody first tried to fix.
- **Questions** (`lib/hecks/questions/`): What a blocked session asks of the operator, tagged by kind, and which kinds the board may answer without a person.
- **RailsApp** (`lib/hecks/rails_app/bluebook/`): Name a Rails app and shape its lists; every page else is derived from the domain.
- **Roundhouse** (`lib/hecks/roundhouse/`): Every session runs only on an admission, is metered for what it draws, blows its own fuse when it overdraws, and is reaped only with nothing unsaved.
- **Signalbox** (`lib/hecks/signalbox/`): The machine's compute is one budget: every session is admitted by headroom, answers one pressure signal by its own rule, and is protected smallest breaker first.
- **Site** (`lib/hecks/site/bluebook/`): Declare a site's routes once and project them into the TypeScript its pages, navigation and CMS read.
- **Tenancy** (`lib/hecks/tenancy/bluebook/`): Which tenants exist, which realm and storage each one owns, and whether each is currently allowed to run, is one queryable, historical fact — not scattered across a world-file overlay and a validation-only command.
- **Tickets** (`lib/hecks/tickets/bluebook/`): Track what Hecks needs, decide it, ship it, and drive GitHub from the record.
- **Triage** (`lib/hecks/triage/`): A red main is one incident: its failing jobs are grouped into causes, each cause is held by one coder at a time, and the incident closes when CI is green on the fix.
- **Delivery** (`lib/hecks/vendor/embryonaut_bluebooks/delivery/bluebook/`): Take finished work onto local main.
<!-- generated:end -->
