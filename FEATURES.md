# Hecks Framework — Feature List

> **Reader's guide.** This file is split into two parts:
>
> 1. The main body below lists features that have an identifier (class name,
>    method, CLI flag, keyword) appearing in at least one test artifact —
>    `spec/`, `hecks_life/tests/`, `hecks_conception/tests/`, `.behaviors`,
>    or `.fixtures`. Presence of an identifier in a test is a weak signal of
>    coverage, not proof — it means the name is exercised, not necessarily
>    that every nuance of the bullet is asserted.
> 2. The final section, **Aspirational (not yet tested)**, collects claims
>    whose identifiers could not be found in any test artifact. They may
>    still work today — they just aren't locked down by a test.
>
> For what is actually exercised right now, run `hecks verify` — it walks
> the contract suite, parity suite, and behavioral tests and reports
> pass/fail per area.
>
> Audit script: `tools/features_audit.py`. Split was produced mechanically
> against the test corpus on 2026-04-22; re-run when tests land to move
> lines back up.

## Domain Modeling DSL

### Core Structure
- Define domains with `Hecks.domain "Name" { }` block syntax
- Declare an explicit domain version with `Hecks.domain "Name", version: "2.1.0" { }` — semver and CalVer supported; propagates to generated gemspec and Go server header
- Define aggregates with attributes, commands, events, policies, queries, and scopes
- Inline aggregate definitions with `definition:` keyword — attaches a human-readable description to the aggregate IR, surfaced in `Hecks.aggregates` inspector output
- Universal `description` keyword — available inside every DSL block (domain, aggregate, command, event, value object, entity, policy, service, workflow, read model, lifecycle). Stored on the IR node and round-tripped through DslSerializer. Feeds glossary, documentation, and LLM context.
- Define value objects as immutable nested types within aggregates
- Define entities within aggregates — sub-objects with identity (UUID), mutable, not frozen
- Multi-domain support with shared event bus across domains
- **Bluebook composes Chapters** — `Hecks.bluebook "Name" { chapter "X" { ... } }` defines a composed system of domains in a single file, with cross-chapter policies and shared event bus via `Hecks.open(book)`
- **Binding (spine)** — `binding "Name" { ... }` in the BluebookBuilder DSL defines the bootstrap layer that holds chapters together: module wiring, registries, errors, utilities, and cross-chapter event routing
- **Self-hosting** — Hecks generates itself from its own Bluebook chapters. Thirteen chapters (AI, Appeal, Binding, Bluebook, CLI, Extensions, Hecksagon, Persist, Rails, Runtime, Spec, Targets, Templating, Workshop) live under `lib/hecks/chapters/` and boot as running Hecks applications via `InMemoryLoader` + `Runtime`.
- **Self-compile manifest** — `Hecks::SelfCompile` lists all chapters in load order with `summary`, `total_aggregates`, `total_commands`, and `missing_chapters` introspection methods. Proves the Bluebook is a complete specification of Hecks.
- **Coverage verification** — `CoverageVerifier` walks all `.rb` files in `lib/` and checks each is covered by at least one chapter aggregate. Integrated into `bin/verify` as Phase 4.
- **Paragraphs** — `paragraph "Ports" { aggregate "EventBus" do ... end }` groups aggregates into named sections within a chapter. Paragraphs are first-class IR nodes (`Structure::Paragraph`) tracked on the domain, enabling organizational splitting without creating separate domains.
- **Bluebook glossary** — `bluebook.glossary` prints the Ubiquitous Language for the entire composed system, walking binding + all chapters and listing every aggregate and command with descriptions.
- Workshop chapter mode — define and play multiple chapters interactively with `workshop.chapter("Name") { ... }`
- Domain version pinning and local path loading in configuration
- **Domain-named source files** — every Hecks source file is named after its declared domain: `<domain>.bluebook` (DSL), `<domain>.hecksagon` (runtime/adapter IR), `<domain>.world` (world concerns + ethics). Discovery is glob-based — `find_hecksagon_files` / `find_world_files` in `lib/hecks/runtime/boot.rb` and `find_world_file` in `hecks_life/src/main.rs` scan for `*.hecksagon` / `*.world` rather than hardcoded filenames. Generators emit `<name>.bluebook` / `<name>.hecksagon`, and `WATCH_EXTENSIONS` in `lib/hecks/capabilities/live_reload/watcher.rb` tracks `.bluebook .hecksagon .world` for hot reload.

### Attributes & Types
- Define typed attributes with String, Integer, Float, Boolean, JSON, Date, DateTime, etc.
- Symbol type shorthand: `:string`, `:integer`, `:float`, `:boolean`, `:date`, `:datetime`
- Default attribute type is String when omitted
- Define collection attributes with `list_of("Type")` syntax
- Define cross-aggregate references with standalone `reference_to "Aggregate"` — first-class domain concept
- Optional role naming: `reference_to "Team", role: "home_team"`
- Cross-domain qualified references: `reference_to "Billing::Invoice"` — exempt from compile-time validation, verified at boot (target domain must be loaded), IDOR reference validation resolves from foreign domain module
- References hold live objects in memory — IDs are purely a persistence concern
- Enum constraints: `attribute :category, String, enum: %w[low medium high]` — validated at runtime, dropdown in UI
- Computed attributes: `computed :lot_size do; area / 43560.0; end` — derived values not stored in the database, shown in UI with "(computed)" hint, visible in `hecks inspect`, and available as MCP `add_computed` tool

### Commands
- Define commands with attributes, handlers, guards, read models, actors, and external system docs
- Auto-infer domain events from commands (CreatePizza → CreatedPizza) with irregular verb support
- Explicit event names with `emits` keyword: `emits "PizzaCreated"` overrides inferred conjugation
- Multiple events per command: `emits "PizzaCreated", "MenuUpdated"` — all are emitted and reach subscribers
- Events carry command attrs + all aggregate attrs by convention — policies can reference any field
- Command `sets` declaration: `sets status: "approved"` — static field assignments
- Define command `call` blocks in DSL for inline business logic (prototyping and play mode)

### State Machines
- Lifecycle DSL: `lifecycle :status, default: "draft" { transition "Approve" => "approved" }`
- Generated status predicates: `model.draft?`, `model.approved?`
- Commands auto-set status to declared target — no hand-editing

### Policies & Events
- Define guard policies (authorization blocks that gate command execution)
- Define reactive policies (event-driven: on event → trigger command, with async option)
- Domain-level policies for cross-aggregate concerns (outside any aggregate block)
- Policy conditions: `condition { |event| event.amount > 10_000 }` — only fires when true
- Policy attribute mapping: `map principal: :amount` translates event attrs to command attrs
- Policy `defaults` for static attribute injection: `defaults entity_type: "AiModel"`
- Define event subscribers with `on_event` for arbitrary side-effect code on events
- Domain-level `on_event` subscribers for cross-aggregate reactions

### Queries & Scopes
- Define named queries with `where`, `order`, `limit`, `offset` chainable DSL
- Define named scopes as hash conditions or lambda predicates

### Specifications & Validation
- Define specifications as reusable composable predicates (`satisfied_by?`, `and`, `or`, `not`)
- Define per-attribute validations (presence, uniqueness, length, format, custom)
- Define aggregate-level and value-object-level invariants as block constraints

### Domain Services
- Domain services: `service "TransferMoney" { dispatch "Withdraw"; dispatch "Deposit" }`
- Services orchestrate multiple commands across aggregates via the command bus
- Wired as methods on the domain module: `Banking.transfer_money(...)`

### Sagas / Process Managers
- Long-running stateful business processes with compensation: `saga "OrderFulfillment" { ... }`
- Block-based step DSL with `on_success`, `on_failure`, and `compensate` per step
- Keyword step syntax for simple cases: `step "DoThing", on_success: "ThingDone"`
- Timeout and on_timeout metadata for time-bounded sagas
- In-memory `SagaStore` for saga instance persistence (swappable for Redis/SQL)
- `SagaRunner` state machine: pending -> running -> compensating -> completed/failed
- Wired as `start_<saga_name>` methods on the domain module: `OrdersDomain.start_order_fulfillment(...)`
- Steps declare success and failure transitions to other named commands
- Saga definitions stored in domain IR and available via `domain.sagas`

### Ubiquitous Language
- `prefer` accepts optional `definition:` kwarg to document preferred terms inline
- Glossary `generate` produces a "Ubiquitous Language" section with definitions and avoid lists

### World Concerns
- **World Concerns Report** — `hecks validate` shows a per-concern PASS/FAIL summary with violations listed
- **GovernanceGuard** — general-purpose governance checker (`Hecks::GovernanceGuard.new(domain).check`) returns `Result` with `passed?`, `violations`, `suggestions`; works from CLI (`--governance`), MCP (`governance_check` tool), REPL, or any entry point

### Access Control & Ports
- Define access-control ports that whitelist allowed methods per consumer
- Import domains from event storm formats (Markdown and YAML)

## Extensions

### Extension Registry
- Extension registry: `Hecks.register_extension(:sqlite) { |mod, domain, runtime| ... }`
- Adapter type classification: `adapter_type: :driven` or `:driving` on `describe_extension`
- Two-phase boot: driven extensions (repos, middleware) fire before driving extensions (HTTP, queues)
- Query helpers: `Hecks.driven_extensions` and `Hecks.driving_extensions`
- Extension aliasing: `Hecks.alias_extension(:short, :long)` registers a shorthand key for an existing extension
- Standard extension format: describe, register, namespace under `Hecks::` (e.g. `Hecks::Audit`, `Hecks::PII`, `Hecks::Queue`)
- Every extension declares its config keys in `describe_extension` for introspection
- Every extension has a "Future gem" comment documenting its intended gem name

### Hecksagon Adapters
- `adapter :kind, ...` — unified DSL for declaring infrastructure adapters; persistence kinds (`:memory`, `:sqlite`, `:postgres`, `:mysql2`, `:mongodb`, etc.) stay unnamed and at most one per hecksagon; `adapter :shell, name: :x` is named and may appear multiple times
- `adapter :shell` — named argv-only subprocess adapter; `command` is a fixed binary, `args` is a list-of-strings with `{{placeholder}}` tokens substituted per-element at dispatch time; supports `output_format` (`:text`, `:lines`, `:json`, `:json_lines`, `:exit_code`), `timeout`, `working_dir`, `env`
- `runtime.shell(:name, **attrs)` — dispatches a shell adapter; returns a `Result` with `output` (format-parsed), `raw_stdout`, `stderr`, `exit_status`
- Shell dispatch security: `Open3.capture3`/`popen3` (no shell), `unsetenv_others: true` (empty env baseline, only declared env entries cross), explicit `working_dir`, sealed empty stdin, active-kill on timeout via pgroup SIGKILL
- `persistence :type, ...` remains as a deprecated alias for `adapter :type, ...` (emits a one-shot warning per builder) — closes the long-standing gap where the public `adapter` DSL was vestigial

### Application Service Extensions
- Default-secure auth: raises `ConfigurationError` at boot when actor-protected commands exist but no `:auth` extension is registered
- Explicit opt-out: `extend :auth, enforce: false` registers a no-op sentinel that satisfies the check
- Auth screens: auto-generated login/signup/logout HTML pages wired into the serve extension (GET/POST `/login`, GET/POST `/signup`, GET `/logout`)
- In-memory credential store for development; default role inferred from domain DSL actor declarations
- Row-level authorization — `owned_by :field` on gates restricts `find`/`all`/`delete` to the current user; `tenancy: :row` isolates by `Hecks.tenant`
- `hecks_metrics` — change tracking for metric-tagged aggregate attributes; `Hecks.metric_log` in-memory log; `Hecks.metric_sink=` pluggable sink for StatsD/Prometheus; `capability.login_count.metric` DSL tag in Hecksagon
- `hecks_bubble` — anti-corruption layer (ACL) for legacy data translation; context DSL with `map_aggregate`, `from_legacy` (field renaming + transforms), `map_out` (reverse mapping); API: `context.translate(:Pizza, :create, legacy_data)` and `context.reverse(:Pizza, :create, domain_data)`

### Domain Connections DSL
- `extend :sqlite` — declare persistence adapter
- `extend :sqlite, as: :write` — named CQRS connections

## Capabilities
- Capability registry: `Hecks.register_capability(:name) { |runtime| ... }` — plug in custom capabilities
- CRUD capability auto-enabled in Workshop play mode and Rails (`Hecks.configure`)

### Bluebook Capabilities (Miette)
- **ProjectManagement** — replaces Linear for tracking features, sprints, priorities, dependencies, milestones, and work logs. Features are domain-aware via DomainLink — every feature links to a bluebook domain. Stored in heki, queryable by Miette. 7 aggregates, 3 policies, seeded with current Linear issues.
- **DLMState** — the DLM tracks itself in Heki. SessionState, GrowthTracker, HonestyTracker, DreamLog, PerformanceMetric, SynapseHistory — 6 aggregates, 18 commands, 5 cross-domain policies. Acceleration rate measures domains conceived per session. Persists across sleep cycles.

### Audit Channel & Dispatch Discipline (Option C)
- **`WriteContext`** — every `.heki` write must declare `Dispatch { aggregate, command }` or `OutOfBand { reason }`. The runtime audits both; out-of-band writes always log to stderr. Direct `heki append/upsert/delete/mark` from the CLI requires `--reason "<why>"` or the call is rejected.
- **Audit log format** — `[heki:<op>] dispatch:Aggregate.Command → path` or `[heki:<op>] out-of-band:<reason> → path`. Greppable; surfaces reach-past rates as a discipline metric.
- **Last-dispatch breadcrumb** — every dispatched command writes `<aggregate>.<command>\n<unix_ts>\n` to `<data_dir>/.last_dispatch`. The statusline renders `🛠️ Item.Add` when fresh (<30s). Only top-level dispatches write; cascade leaves don't overwrite.
- **`HECKS_DAEMON=1` suppression** — body daemons (mindstream, heart, breath, pulse_organs, consolidate) export `HECKS_DAEMON=1`; the runtime skips the breadcrumb write so daemon traffic doesn't drown out human-driven dispatches in the statusline. Audit log + repository writes still fire normally.
- See: `docs/usage/audit_channel.md`

### Entity Primitive
- **`entity` keyword** — declares an identity-bearing entity inside an aggregate, alongside `value_object` (no identity, replaced wholesale). Use when you need addressable parts that exist only within a parent. Mirrors `value_object` syntax; adds an `entities: Vec<Entity>` field on the IR `Aggregate`.
- **Parser + IR + dump** — `parse_entity` mirrors `parse_value_object`, `dump.rs` emits the `entities` array, `canonical_ir.rb` includes it in parity output. Existing aggregates default to `entities: vec![]` without IR drift.
- See: `docs/usage/entity_primitive.md`

### CLI Subcommand Catalog
- **Subcommand catalog** — every `hecks-life` subcommand declared as a row in `information/subcommand.heki`, not a hardcoded match arm in `main.rs`. Shape lives in `capabilities/subcommand/subcommand.bluebook` (`Subcommand` aggregate with name, handler, ArgvShape, description, deprecated).
- **`lookup_subcommand` gate** — `main.rs` consults the catalog before dispatch, without booting the runtime; resolves the handler, honors `deprecated=true`. `help` / `--help` migrated as the first token through the gate (PR #482).
- **Multi-domain split** — `cli/`, `argv/`, `subcommand/` as sibling capabilities; `cli.bluebook` declares a `Phase` entity for parse / resolve / dispatch / emit phases.
- **Bulk register (Many-form)** — `Antibody.RegisterExemptions` takes `list_of(ExemptionSpec)`; the runtime detects the bulk shape (one `list_of(VO)` attr where the VO carries the aggregate's identity field) and iterates, emitting one event per row. The pattern generalises to any Register* command. Retires the seed shell-loop reach-past pattern. (PR #483)
- See: `docs/usage/cli_subcommand_catalog.md`

### Parity Suite
- **Ruby ↔ Rust IR conformance** — `spec/parity/parity_test.rb` runs every fixture through both parsers (Ruby DSL + hecks-life), converts each output to a canonical JSON shape, and diffs. 43/43 baseline (13 synthetic fixtures + 30 real bluebooks).
- **Canonical shape contract** — hand-written on both sides (`hecks_life/src/dump.rs` + `spec/parity/canonical_ir.rb`). The JSON shape IS the contract, not auto-derived.
- **`hecks-life dump <file.bluebook>`** — emits canonical JSON IR. Same shape the Ruby canonicalizer produces.
- **Known-drift list** — `spec/parity/known_drift.txt` documents expected disagreements (currently empty). Fixtures listed here report ⚠ instead of blocking; if a known-drift file starts passing, the suite reports ⚑ and tells you to remove the line.
- **Pre-commit gate** — `bin/git-hooks/pre-commit` blocks unexpected drift in ~1 second. Install with `bin/install-hooks`.
- **Self-description** — `aggregates/bluebook.bluebook` declares the IR shape both parsers must produce (13 aggregates, one per IR concept: Domain, Aggregate, Attribute, ValueObject, Reference, Command, Query, Given, Mutation, Lifecycle, Transition, Policy, Fixture).
- **Nursery soft coverage** — `spec/parity/parity_test.rb` adds `hecks_conception/nursery/**/*.bluebook` as a `soft: true` section; every nursery fixture runs on every parity run, drift is reported and counted, but soft failures do not contribute to the CI exit code. Hard sections (synthetic + real + capability + catalog + misc) stay at 115/115. Promotion to a hard section happens once the systemic Ruby parser bugs (inbox i1/i2) land.

## Shebang Scripts (hecks-life run)

### Bluebooks as executables
- `#!/usr/bin/env hecks-life run` at the top of a `.bluebook` file + `chmod +x` makes it directly executable
- `entrypoint "CommandName"` inside `Hecks.bluebook "…" do … end` declares the default command to dispatch
- Argv `key=value` pairs bind as attributes on the entrypoint command
- Exit codes: 0 clean, 1 parse failure, 2 guard failure (no entrypoint), 3 adapter failure, 4 command not found

### Companion hecksagon
- Rust runtime parses `adapter :memory / :heki / :stdout / :stderr / :stdin / :env / :fs / :shell`
- Shell adapters execute via std::process::Command with parity to `lib/hecks/runtime/shell_dispatcher.rb` (env_clear, timeout with SIGKILL, `{{placeholder}}` substitution, `:text / :lines / :json / :json_lines / :exit_code` output formats)

### Interactive capability
- When a hecksagon declares both `:stdin` and `:stdout` and the bluebook exposes `ReadLine` + `RespondWith`, `hecks-life run` drives the full REPL through the declared adapters — no Rust-specific I/O code
- Terminal REPL lives as `hecks_conception/capabilities/terminal/terminal.bluebook` + `terminal.hecksagon`, not Rust
- Legacy interactive REPL (old `hecks-life run`) preserved as `hecks-life repl <file>`

## Runtime API
- `Hecks.boot(__dir__)` — find domain file, validate, build, load, and wire in one call
- `Hecks.boot(__dir__, adapter: :sqlite)` — automatic SQL setup
- `Hecks.boot(__dir__) { extend :sqlite }` — boot block with connections
- `Hecks.load(domain)` — load domain and wire runtime in one step
- `app.on("EventName") { }` — subscribe to events at runtime
- `app.run("CommandName", attrs)` — dispatch commands
- `Hecks.boot(__dir__)` auto-detects multi-domain when `bluebook/` has multiple Bluebook files
- `app.dry_run("CommandName", attrs)` — preview command result without side effects (no persist, no events)
- Dry-run validates guards, preconditions, postconditions and traces the reactive policy chain

## Code Generation

### Auto-Boot
- Generated gems auto-boot: `require "cats_domain"` wires a Runtime with memory adapters
- Generated gems include `hecks` as a dependency and auto-load `hecks_domain.rb`
- Override with `CatsDomain.boot(adapter: :sqlite)` or `HECKS_SKIP_BOOT=1`

### Generated Artifacts
- Generate complete Ruby gems from domain definitions with `Hecks.build(domain)`
- `Hecks.load(domain)` loads domain in memory; file-based or fast in-memory strategy
- Generate aggregate classes with `Hecks::Model` mixin, auto-UUID, and timestamps
- Generate command classes with full lifecycle (guard → handler → call → persist → emit → record)
- Generate frozen event classes with `occurred_at` timestamps
- Generate entity classes with `Hecks::Model` (UUID, mutable, identity equality)
- Generate specification classes with `Hecks::Specification` mixin
- Generate query object classes with chainable query builder
- Generate guard and reactive policy classes
- Generate event subscriber classes under `Aggregate::Subscribers`
- Generate frozen value object classes with invariant enforcement
- Generate in-memory repository adapters
- Generate SQL (Sequel-based) repository adapters with schema definitions
- Generate SQL migration files from domain diffs

### Generated Specs
- Behavioral RSpec specs — validations, identity, events, attributes, invariants
- Command specs: runtime execution with persistence + event log validation
- Query specs: concrete filter assertions with matching/non-matching data
- Policy specs: full reactive event chain verification
- Lifecycle specs: state walk through every transition with event log
- Specification specs: satisfied_by? pass/fail with sample objects
- Scope specs: static and callable scopes with filtered results
- View specs: event projection state updates
- Workflow specs: execution and event production
- Service specs: dispatch verification and result checking
- Port specs: allowed methods pass, denied methods raise PortAccessDenied

### Generation Features
- Port enforcement stubs, autoload registries, gem scaffolds
- Preview generated source for any aggregate without writing files
- Auto-include mixins by convention — `include Hecks::Command` in generated files
- Auto-generate OpenAPI, JSON-RPC discovery, JSON Schema, TypeScript types (.d.ts), and glossary docs on build
- TypeScript type generation — interfaces for aggregates/value objects/entities, types for commands/events, enums for lifecycles, union types for enums; `hecks dump --types` for standalone export
- Preserve custom `call` methods on regenerate
- Resolve domains from installed gems, not just local files

### Self-Hosting Analysis
- `FrameworkGemGenerator` — locates actual files by aggregate name, generates skeletons with correct module nesting and method stubs from commands
- Programmatic API via `SelfHostDiff.new(domain, gem_root:, mode: :framework).summary`
- Hecksagon baseline: 93.3% coverage (28/30 files have partial matches from IR-derived skeletons)

### CLI (hecks_cli)
- `lib/hecks_cli/cli.rb` — Thor-based command-line entry point
- IR attribute types map to Thor option types (String→:string, Integer→:numeric, etc.)

### Self-Hosting DSL Extensions
- `namespace "Hecksagon::DSL"` — declares the module nesting for an aggregate, used by skeleton generator
- `includes "SqlBuilder"` — declares module mixins included in the aggregate

## HecksUL Language Specification
- `HecksUL` (Ubiquitous Language) — every Hecks domain is its own executable business language
- `HecksUL.compiler` — Bluebook DSL frontend, DomainModel IR, multiple backends
- `HecksUL.self_hosting` — live chapter/aggregate/command counts from Hecks's own Bluebook definitions
- `ChapterSpecGenerator` — generates exhaustive RSpec specs from chapter IR (chapter + paragraph level)
- Generated specs cover every aggregate and command across all 15 chapters — the language spec IS the test suite

## Persistence
- Memory adapter for fast, zero-setup in-process storage
- Repository pattern: `find`, `all`, `count`, `save`, `delete` on aggregates
- Instance-level `save`, `destroy`, `update` methods
- Collection proxies for `list_of` attributes with `create`, `delete`, `each`, `count`
- Optional event sourcing with `EventRecorder` and `Aggregate.history(id)` replay

## Querying
- `order(:field)` and `order(field: :desc)` sorting
- OR conditions: `Pizza.where(style: "Classic").or(Pizza.where(style: "Tropical"))`
- Batch operations: `delete_all`, `update_all(status: "archived")`
- Query operators: `gt`, `gte`, `lt`, `lte`, `not_eq`, `one_of`

## Command & Event System
- Command bus with middleware pipeline
- Instance-level command methods: `cat.meow` auto-fills from instance attributes
- Re-entrant policy protection (skips policies already in-flight)
- Cross-aggregate event subscribers

## Smalltalk-Inspired REPL

### Sketch & Play
- Dynamic REPL prompt: `hecks(scratch sketch)`, `hecks(banking play)`
- Last event in prompt: `hecks(pizzas play) [CreatedPizza]` — shows most recent domain event
- `last_event` — returns the most recent event object for inspection
- Real return values: commands return the aggregate with a concise `inspect` showing attributes, not just "ok"

### Named Constants & System Browser
- Named constants: `aggregate("Cat")` creates `Cat` constant in the REPL
- System browser: `browse` prints a tree of all domain elements
- Deep inspect: `deep_inspect` prints full structural breakdown of all aggregates with nested value objects, entities, commands, params, events, policies, validations, queries, scopes, specifications, subscribers, and references
- Deep inspect single aggregate: `deep_inspect("Pizza")` inspects one aggregate only
- Navigator/Renderer architecture: Navigator walks the domain IR tree, Renderer formats each element — composable for custom output formats

### One-Line Dot Syntax
- Implicit attributes: `Post.title String` adds attribute via method_missing
- Implicit commands: `Post.create` creates CreatePost command, returns CommandHandle
- Lifecycle from handle: `Post.lifecycle :status, default: "draft"`
- Transitions from handle: `Post.transition "PublishPost" => "published"`
- Value objects via PascalCase + block: `Post.Address { attribute :street, String }`
- Commands via snake_case + block: `Post.bake { attribute :temp, Integer }`
- Reference attributes: `Post.order_id reference_to("Order")`

### Console Tour
- Guided walkthrough via `hecks tour` — 15-step tour of sketch, play, and build
- Also available inside the console: `tour`
- CI-friendly: skips Enter pauses when stdin is not a TTY

### Architecture Tour
- Covers monorepo layout, Bluebook DSL, Hecksagon IR, compiler pipeline, generators, workshop, AI tools, CLI registration, and spec conventions
- Each step displays relevant file paths for exploration

### Web Console
- Browser-based REPL via `hecks web_console [NAME]` — terminal-like interface at localhost:4567
- Safe command parser: no eval, only whitelisted Grammar commands execute
- Console endpoint disabled by default — requires `--enable-console` flag to activate
- Multi-domain support: load multiple domain files into a single web console with domain grouping
- Three-panel layout: domain tree sidebar, terminal center, event log sidebar
- Same implicit syntax as IRB — commands parsed as a safe command language
- Paren-style command syntax: `create_pizza(name: "Margherita")` alongside space-delimited
- Side panels auto-refresh after each command
- Command history with Up/Down arrows
- Web Components (Shadow DOM) for diagram rendering with custom events

### Session Features
- All session methods hoisted to top level in console
- AggregateHandle short method names: `attr`, `command`, `validation`, etc.
- Duplicate attribute detection
- Auto-normalize names to PascalCase
- `serve!` — start web explorer from REPL in background thread
- Play mode compiles domain on the fly with full Runtime
- Real-time event display and policy triggering feedback
- Event history with timestamps, reset/replay capability
- Suppressed backtraces by default — `backtrace!` / `quiet!` to toggle
- Persistent command history across sessions (`~/.hecks_history`)
- Image files stored in `.hecks/images/` with human-readable `.heckimage` format

## Vertical Slice Architecture (hecks_features)
- Extract vertical slices from domain reactive chains: command → event → policy → downstream command
- `domain.slices` returns `VerticalSlice` objects with entry command, steps, aggregates, cycle detection
- `domain.slices_diagram` generates Mermaid flowchart with each slice as a labeled subgraph
- Cross-aggregate detection: `slice.cross_aggregate?` when a slice spans multiple aggregates
- Leaky slice validation: warns when aggregate-scoped policies trigger commands on other aggregates
- Slice introspection: `commands`, `events`, `policies`, `depth` on each slice

## Validation & DDD Rules
- No duplicate aggregate names
- References must target aggregate roots
- No bidirectional or self-references on aggregates
- Value objects must not contain references
- Aggregates must have at least one command
- Name collision detection across aggregates/VOs/entities
- Ruby keyword and reserved attribute name detection
- Every validation error includes a structured `hint` field with a fix suggestion -- rendered as colored "Fix:" lines in the CLI, included in `ValidationError` exception messages, and accessible via `error.hint` / `error.to_h`
- Implicit foreign key detection: warns when `_id String` should be `reference_to("Aggregate")`
- Validator collects non-blocking warnings alongside blocking errors
- **Fat bluebook warning** — if a domain has more than 7 aggregates, `hecks-life validate` emits a soft WARNING suggesting bounded context splitting (domain still passes as VALID)
- **Mixed concerns warning** — if a domain with 5+ aggregates has disconnected aggregate clusters (no references or policies connecting them), `hecks-life validate` warns they may belong in separate bounded contexts

### Lifecycle Validator (`hecks-life check-lifecycle`)
- **Unreachable from_state** — flags transitions whose `from:` value is neither the lifecycle default nor any other transition's to_state (dead transition)
- **Stuck default** — warns when no transition can fire from the default state (aggregate stuck forever)
- **Unreachable given** — flags `given { field == "X" }` predicates where no command sets `field` to `X` (the gate can never open)
- **Mutation reference check** — flags `then_set :event, to: :event` where `:event` matches no command attribute or reference (field stays null at runtime)
- **Clock anti-pattern check** — flags `then_set :ts, to: :now` and `seconds_since(:field)` patterns where the domain reaches into the system clock. Hint: inject time as a command attribute (DDD Clock port) so the caller (test, hecksagon adapter, app) supplies the timestamp.

### Duplicate Policy Validator (`hecks-life check-duplicate-policies`)
- Refuses bluebooks that declare two or more reactive policies wired to the same `(on_event, trigger_command)` pair. The runtime fires every matching policy in declaration order, so the trigger runs once per duplicate — a silent cascade bug
- Flat IR walk: groups every reactive policy (aggregate-scoped and domain-level) by `(event, trigger[, target_domain])`, reports one error per group of size ≥ 2, naming every colliding policy and the exact duplicate count
- Target-domain keyed: cross-domain wiring (`@target`) does not collide with same-domain policies
- Parity: Ruby rule `Hecks::ValidationRules::Structure::DuplicatePolicies` runs inside `Hecks.validate`; Rust subcommand `hecks-life check-duplicate-policies <bluebook>` exits non-zero on any duplicate pair

### IO Validator (`hecks-life check-io`)
- Asserts the bluebook is pure-memory by default — no IO leaks above the hecksagon adapter layer
- **Static IR scan**: flags IO-suggestive command names (`Deploy`, `Send`, `Push`, `Publish`, `Fetch`, `Sync`), past-tense external event names (`Deployed`, `Sent`), and pure-side-effect commands (emits but no state change, not Create or lifecycle)
- **Runtime smoke**: boots `Runtime::boot(domain)` (pure-memory, no `data_dir`, no hecksagon) and dispatches every dispatchable command — anything that panics or attempts IO is a hard error

### Behavioral Tests (`hecks-life conceive-behaviors` + `behaviors`)
- New first-class DSL: `Hecks.behaviors "Pizzas" do ... end` — sibling to `Hecks.bluebook`, separate IR, separate parser, separate parity contract
- Test surface: `tests`, `setup`, `input`, `expect` — no IDs in the test bluebook (runner translates references↔ids internally)
- `conceive-behaviors` auto-generates `_behavioral_tests.bluebook` from any source bluebook by walking IR (every command, query, lifecycle transition, given clause)
- `behaviors` runner uses `Runtime::boot(domain)` — pure-memory, no hecksagon, no adapters
- Cascade-aware test generation: detects policy chains (emit→trigger), asserts on cascaded final state, skips redundant mid-chain tests
- Conceiver parity test (`tests/conceiver_parity_test.rs`) keeps the bluebook conceiver and behaviors conceiver from drifting (shared `Conceiver` trait + shared `conceiver_common.rs` infrastructure)
- **VCR-style cascade lockdown** — for every command whose emit fires a policy chain, the conceiver emits a `kind: :cascade` test asserting the exact ordered list of events the runtime will publish (`expect emits: [E1, E2, ...]`). Drift in the policy graph (added or removed policy, retargeted trigger) breaks the test immediately.
- **Static cascade walker** (`hecks_life/src/cascade.rs`) — extracts the predicted event list from emit→policy→trigger graph; mirrors runtime `PolicyEngine` cycle detection (a policy is blocked while on the recursion stack, allowing diamond fan-in)
- **Cross-aggregate cascade setups** — generator walks `aggregates_touched_by_cascade` and emits a `Create` setup for every aggregate the cascade hops through, so triggered cross-aggregate commands find their target records
- **Two dispatch modes in the runner** — `dispatch` cascades policies (used by `kind: :cascade` tests), `dispatch_isolated` skips policy drain (used by setups so they don't overshoot the precondition state being tested)
- **`as:` reference alias kwarg** — canonical: `reference_to(Order, as: :recent_purchase)`. Five forms accepted: bare, `as:`, `role:` (legacy), `.as(:foo)` suffix, trailing-symbol shorthand
- **Clock anti-pattern check** — `lifecycle_validator` flags `:now` and `seconds_since(:field)` in mutations and givens. Time is infrastructure; the caller (test, hecksagon adapter, app) provides timestamps as command attributes.
- **Compound boolean givens** — interpreter supports `||` and `&&` (top-level split, `&&` binds tighter), plus `==`, `!=`, `>=`, `<=`, `>`, `<`, `field.any?`, `field.empty?`
- **List literal mutations** — `then_set :items, to: []` resolves to `Value::List(vec![])` (not `Str("[]")`); `then_set :items, to: [a, b]` resolves each element through the same value resolver

## Self-Governance

### Antibody — Five-DSL Vocabulary Enforcement
- **Five canonical source DSLs** — Hecks source is `.bluebook`, `.hecksagon`, `.fixtures`, `.behaviors`, `.world`. Bluebook is Turing-complete and dispatched directly by `hecks-life` (no compile step, no generated artifacts); every non-DSL file is a gap to be closed, rewritten as one of the five, or justified with a concrete per-commit exemption.
- **`bin/antibody-check`** — scans a commit's staged (or HEAD) diff for files outside the five-DSL extension set and reports them with reasons; exit code non-zero when unexempt flagged files are present
- **Per-commit exemptions, not permanent carve-outs** — `[antibody-exempt: <reason>]` marker must appear on its own line in the commit message (regex anchored to line start so prose examples don't match) and justifies one specific change; no allowlist file, no pre-approved categories, thin reasons (`runtime`, `temporary`, `bootstrap`) are the smell the antibody is designed to prevent
- **Scan semantics are per-commit** — `commit-msg` reads only the in-flight commit message and its staged files; earlier commits' exemption markers cannot leak into later commits on the same branch
- **Pre-commit hook Gate 5** (`bin/git-hooks/pre-commit`) — informational, prints the flagged file list before the author writes a commit message, never blocks
- **Commit-msg hook Gate B** (`bin/git-hooks/commit-msg`) — blocking; reads the in-flight commit message from git's `$1`, rejects with a COMMIT BLOCKED banner when non-DSL files are staged without a matching exemption
- **CI workflow** (`.github/workflows/antibody.yml`) — blocking second layer; runs `bin/antibody-check --each-commit` which walks every commit in `base..HEAD` and validates each one in isolation; emits GitHub `::warning::` annotations on flagged files so they appear inline on the PR diff

## Domain Interface Versioning
- Breaking change classification: removed commands, removed attributes, removed aggregates marked as BREAKING
- Non-breaking changes: added commands, added attributes, added queries, added scopes
- Auto-bump domain version on breaking changes: `hecks build` compares against the latest tagged snapshot and auto-bumps CalVer when breaking changes are detected

## Migrations & Schema Evolution
- `DomainDiff` detects added/removed aggregates, attributes, VOs, entities, commands, policies, validations, invariants, queries, scopes, subscribers, specifications
- SQL migration strategy generates Sequel-compatible files
- NOT NULL from `validation :field, presence: true`
- UNIQUE from `validation :field, uniqueness: true`
- DEFAULT values from attribute defaults
- Foreign key cascading for join tables and references
- Auto-indexes on reference columns

## Documentation Generation
- `hecks visualize` — CLI command prints Mermaid diagrams to stdout, file, or browser HTML page
  - `--type structure` — classDiagram of aggregates, attributes, value objects, entities
  - `--type behavior` — flowchart of command-to-event flows and policy chains
  - `--type flows` — sequenceDiagram of reactive chain flows
  - `--type slices` — slice flowchart with subgraph per vertical slice
  - `--type ports` — hexagonal port diagram showing driving/driven adapters around the domain
  - `--type aggregate-ports` — per-aggregate port diagram: commands as driving-port arrows (left), optional Persistence/EventBus as driven-port nodes (right); pass `show_persistence:` / `show_event_bus:` to enable driven nodes
  - `--browser` — self-contained HTML with Mermaid CDN opened in browser
  - `--output <file>` — write Mermaid markdown to a file
- `hecks context_map` — CLI command renders DDD context map of bounded context relationships
  - Text summary to stdout by default (bounded contexts, cross-domain event flows, shared kernels)
  - `--mermaid` — Mermaid graph TD diagram with subgraphs per domain and event arrows
  - `--browser` — self-contained HTML with Mermaid CDN opened in browser
  - `--output <file>` — write Mermaid markdown to a file
  - Reads multiple domains from a `domains/` directory or a single Bluebook
  - Detects cross-domain relationships via reactive policies that listen to foreign events
  - Identifies shared kernels (domains referenced by two or more other domains)
- Domain glossary with English descriptions
- Mermaid class diagrams and flowcharts
- DSL serializer: round-trip compiled domain back to DSL source code

## AST-Based Domain Extraction (HEC-476)
- `Hecks::AstExtractor.extract(source)` — parse Bluebook DSL source into a plain hash IR using `RubyVM::AbstractSyntaxTree`, no eval
- `Hecks::AstExtractor.extract_file(path)` — read and parse a Bluebook file from disk
- Supports implicit PascalCase aggregate syntax (e.g. `Pizza do ... end` instead of `aggregate "Pizza" do ... end`)
- Safe for static analysis, linting, and tooling — never executes domain code

## Gem Architecture
- Core `hecks` gem has zero runtime dependencies
- Each extension is a top-level gem candidate at `lib/`
- `require "hecks"` gives you the core; each extension is a separate require
- Flattened namespace: `Hecks::Runtime`, not `Hecks::Services::Runtime`
- Domain gems are the bounded context boundaries

### Module Infrastructure (hecks_modules)
- Zero module-level instance variable assignments — all state lazy-initialized on first access

### Deprecation System (hecks_deprecations)
- Modules prepend warning wrappers onto target classes with `[DEPRECATION]` messages
- Covers hash-style `[]`, `to_h`, `== Hash` on refactored value objects
- Generated examples exclude this module — always use current API

### Rails Import (Reverse Engineering)
- Model-only extraction: works without schema.rb using belongs_to/has_many/validations/enums/AASM
- Auto-generates Create commands for each aggregate
- Preview mode with `--preview` flag

## Autophagy: Self-Hosting Compiler (Hecks v0)
- **Prism AST analysis** — uses Ruby's built-in Prism parser for dependency resolution
- **Bluebook IR consultation** — resolves method-call dependencies via chapter definitions
- **Two-layer dependency graph**: Layer 1 = Prism (constant refs, inheritance, mixins), Layer 2 = Bluebook (method-call edges)
- **Source files are require-free** — all internal requires stripped, Bluebook defines load order
- **SourceTransformer** — strips requires and expands compact class syntax at compile time
- **ConstantResolver** — namespace-aware constant resolution across all source files
- **CycleSorter** — greedy topo sort within dependency cycles, respecting wiring file order
- The compiled binary bundles all source files in load order with zero internal requires
- The binary supports `boot`, `version`, and `self-test` commands
- Binary target also available via `hecks build --target binary`
- Self-hosting: compiled Hecks can boot domains identically to interpreted Hecks

## Runtime Code Generation
- **RuntimeGenerator** — generates Ruby wiring modules from Bluebook + Hecksagon IR
- 7 sub-generators produce `Hecks::Runtime::Generated::*` modules that shadow hand-written mixins:
  - **RepositoryWiring** — per-aggregate memory repository instantiation
  - **PortWiring** — Persistence/Commands/Querying/Introspection bind calls per aggregate
  - **SubscriberWiring** — event bus subscriptions from aggregate subscribers
  - **PolicyWiring** — reactive policy subscriptions with re-entrancy guards
  - **ServiceWiring** — domain service singleton method definitions
  - **WorkflowWiring** — workflow executor method definitions
  - **SagaWiring** — saga runner method definitions
- Framework code (CommandBus, EventBus, port adapters, mixins) stays hand-written
- Called explicitly via `RuntimeGenerator.new(domain, domain_module:).generate`

## CLI Commands
- `hecks new NAME` — scaffold a complete project with interactive world goals onboarding: 3-step prompt (yes/skip/doesn't apply), maps each goal to a real extension (`privacy→:pii`, `transparency→:audit`, `consent/security→:auth`, `equity→:tenancy`, `sustainability→:rate_limit`), deduplicates extensions, generates both `world_concerns` and `extend` calls in the Bluebook; `--no-world-goals` skips prompt for CI
- `hecks build --gem` — produce a publishable `.gem` artifact after building (runs `gem build` on generated output); supported for `ruby` and `static` targets
- `hecks console [NAME]` — interactive REPL with domain loaded
- `hecks tree` — print all CLI commands as a grouped tree; `--format json` for tooling
- `hecks interview` — conversational onboarding that walks through domain definition interactively (name, aggregates, attributes, commands) and writes a Bluebook file
- `--format json` on `validate`, `inspect`, and `tree` commands for Studio/tooling consumption

## Rails Integration (ActiveHecks)
- Auto-detects `*_domain` gems in the Gemfile — zero config needed
- Auto-registers domain gem constants in Rails app
- SQL adapter config with database/host/name options
- Multi-domain support within a single Rails app
- Rails generators registered dynamically via Railtie
- `rails generate active_hecks:init` — one command sets up everything:
  - Adds `hecks_on_rails` to Gemfile
  - Detects domain gems (local directories or installed gems)
  - Creates initializer and app/models/HECKS_README.md
  - Enables ActionCable, creates cable.yml, mounts at /cable
  - Pins Turbo via importmap, adds turbo_stream_from to layout
  - Wires test helpers into spec/test files

## HecksLive — Real-Time Domain Events
- Zero-config real-time event streaming via ActionCable + Turbo Streams
- Every domain event auto-broadcasts to connected browsers
- Railtie wires `event_bus.on_any` → `Turbo::StreamsChannel.broadcast_prepend_to`
- Works across page navigations with `data-turbo-permanent`
- Custom channels via `HecksLive::Channel` subclass with `subscribe_to`

## Module Structure (HEC-370)
- `bluebook/` — grammar, IR nodes (`Structure::Domain`, `Structure::Aggregate`, …), DSL builders, validators, compiler, generators, visualizer, event storm parser
- Meta-gem loader (`lib/hecks.rb`) adds all sub-gem `lib/` directories to `$LOAD_PATH`
- No Ruby namespace changes — only gem directory ownership changed during consolidation

## Packaging
- **Mono-gem** — all framework code lives in a single `lib/` directory, organized by chapter: `ruby -Ilib` is all you need
- `Chapters.load_chapter` supports `base_dirs:` for scoped multi-directory loading
- Extensions auto-wire when present — no configuration needed
- See [Packaging](docs/usage/packaging.md) for the full breakdown

## Code Generation — list_of Semantics
- Commands that add to `list_of` collections generate proper append logic
- `AddTopping` command generates `existing.toppings + [Topping.new(name: topping)]`
- `CollectionProxy` supports `+` operator for generated command compatibility

## AI-Native

### MCP Server
- `Hecks.load(domain)` is the public API for booting a Runtime from an IR object in memory
- Tool descriptions include parameter constraints, example values, return shapes, and guard conditions
- Rich descriptions for command tools: required attributes, emitted event, guards that might reject
- Every MCP tool produces visible human-readable feedback in Claude Code conversations
- All tool output uses `capture_output` to show the same terse feedback as the REPL

### Command Bus Port (HTTP Adapter Boundary)
- Mutations route through the `CommandBus` middleware pipeline via `port.dispatch`
- Reads validate against a safety whitelist (blocks `eval`, `system`, `exec`, `send`, etc.)
- Port-level middleware fires before the command bus — `port.use(:name) { |cmd, attrs, next_fn| ... }`
- Port middleware can short-circuit requests without reaching the domain
- `DomainServer` and `RpcServer` both use the port for all dispatch

### Self-Discoverable HTTP API
- `GET /_schema` returns JSON Schema definitions
- AI agents hitting the HTTP API can self-discover every endpoint and type

### Structured JSON Errors
- All error classes (`GuardRejected`, `ValidationError`, `PreconditionError`, etc.) have `as_json`/`to_json`
- Returns error type, command, aggregate, message, and fix suggestion as machine-readable JSON
- AI agents can act on failures programmatically without string parsing

### Claude Code Integration
- Watcher scripts in `bin/`: `watch-all`, `watch-autoloads`, `watch-cli`, `watch-cross-require`, `watch-file-size`, `watch-spec-coverage` — poll every second and append to `tmp/watcher.log`
- `PostToolUse` hook (configured in `.claude/settings.json`) reads `tmp/watcher.log` after every Edit/Write/Bash so Claude sees watcher output inline
- Watcher processes are cleaned up automatically when Claude exits

### Watcher Agent (hecks_watcher_agent)
- Post-commit hook auto-launches agent when watchers report issues
- Pure Ruby fixes: autoload entries, skeleton spec files
- Cross-require violations skipped (needs architectural decision)
- Creates branch, commits fixes, opens PR via `gh`

### Gem Packaging
- `hecks gem build` builds all component gems and the meta-gem via GemBuilder
- Components without a gemspec are skipped with a warning

### Domain Flow Generation
- `domain.flows` generates plain-English descriptions of reactive chains: command → event → policy → command
- `domain.flows_mermaid` generates Mermaid sequence diagrams of the same flows
- Cycle detection with `[CYCLIC]` markers

### Domain Serialization
- Aggregates with attributes (name, type, flags), commands, queries, specifications, policies, validations, invariants, value objects, entities
- Domain-level policies and services included

## Static Domain Generation (hecks_static)

### Zero-Dependency Output — Full DSL Parity
- All DSL concepts generated: aggregates, value objects, entities, commands, events, ports, queries, validations, invariants, lifecycles, specifications, policies
- Generated project includes inlined runtime (Model, Command, EventBus, QueryBuilder, Specification)

### HTTP Server & UI
- Hot reload via `--watch` flag — polls domain source directory, reloads Bluebook and rebuilds routes on change (no restart needed, thread-safe via Mutex)
- HTML UI with index tables, show pages, create/update forms
- Query routes: `GET /aggregates/queries/name` for each DSL-defined query
- Query parameter type coercion: Integer params use `strconv.ParseInt`, Date params use `time.Parse` instead of raw strings
- Scope routes: `GET /aggregates/scopes/name` for each DSL-defined scope
- Specification routes: `GET /aggregates/specifications/name?id=` for predicate checks
- View routes: `GET /_views/name` for read model state
- Workflow routes: `POST /_workflows/name` for workflow execution
- Service routes: `POST /_services/name` for service execution
- Live reload — watches `lib/` for file changes, reloads automatically
- Config page to switch roles and persistence adapters at runtime
- Lifecycle badge on show pages — purple status badge with transition hint map
- Direct-action buttons — commands with no user fields POST immediately (no empty form)
- `reference_to` fields render as dropdowns populated from the referenced aggregate
- Reference columns (`_id` attrs) show entity name instead of raw UUID, with short-ID fallback
- Enum fields render as `<select>` dropdowns with valid values
- Humanized labels everywhere — PascalCase split + ActiveSupport pluralization via UILabelContract
- Nav sidebar grouped by origin domain in multi-domain servers

### Port-Based Access Control
- Ports defined in DSL (`port :admin`, `port :customer`) enforced at domain level
- UI buttons faded for unauthorized actions, forms blocked with error message
- JSON API returns 403 for unauthorized commands

### Validation (hecks_validations extension)
- Client-side JS validates before submit (presence, positive)
- Server-side validation check before dispatching to domain
- Domain-level `ValidationError` with `field:` and `rule:` for inline error display
- Three layers, one source: client → server → domain

### Persistence Adapters
- Memory adapter (default) — Hash-backed, zero config, always included
- Filesystem adapter — JSON files in `data/<aggregate>s/<uuid>.json`, survives restarts
- Switchable at runtime via Config page or `--adapter=` CLI flag

### Project Structure
- `lib/` — domain code, runtime, server, adapters (regeneratable)

## Extensions

### hecks_filesystem_store
- JSON file persistence extension for dynamic mode
- `Hecks.boot(__dir__, adapter: :filesystem)` explicit wiring
- Same interface as memory: find, save, delete, all, count, query, clear

### hecks_validations
- Server-side parameter validation from domain rules
- Reads validation rules and VO invariants from domain IR at boot

## Go Domain Generation (hecks_go)

### Go Output from Same DSL
- Value object structs with constructor invariant checks (`NewTopping()`)
- Event structs with `EventName()` and `GetOccurredAt()`
- Repository interfaces (Go's native port enforcement — compile-time, not runtime)
- Memory adapters with `sync.RWMutex` + `map`
- HTML UI with template-rendered pages: home, index tables, show detail, create/update forms, config page
- `hecks_templating` gem — shared data contracts for cross-target code generation:
  - `ViewContract` — view data shapes, short ID display, Go struct generation
  - `TypeContract` — single type registry (Go, SQL, JSON, OpenAPI, TypeScript) + `format_go_literal` for typed comparisons
  - `EventContract` — event interface, required fields (aggregate_id, occurred_at)
  - `EventLogContract` — JSON shape for `/_events` endpoint (same format Ruby and Go)
  - `MigrationContract` — validates round-trip serialization fidelity
  - `AggregateContract` — standard fields, validations, enums, lifecycle, self-ref detection
  - `DisplayContract` — cell rendering, lifecycle transitions, aggregate summaries, policy labels, home data
  - `FormParsingContract` — type coercion for form submissions (Go parse lines, Ruby coerce expressions)
  - `UILabelContract` — PascalCase splitting, ActiveSupport pluralization, plural_label
- Contract-driven Go templates (ShowTemplate, FormTemplate, IndexTemplate) — no ERB conversion or regex patching
- Self-ref detection for multi-word aggregates via `AggregateContract.agg_suffixes` (policy_id matches GovernancePolicy)
- Browser-style HTTP smoke test: GET form → parse HTML → POST form-urlencoded → follow redirect → verify show page
  - Tests every command, query, specification, lifecycle transition, view, workflow, service
  - Validates event log after commands and lifecycle walks
  - Verifies show page contains expected state after transitions
  - Resets server data before and after each run via `POST /_reset`
- Form submission: accepts both JSON and form-urlencoded, redirects on success
- Config page with roles, adapter, policies, aggregate counts, ports
- Config page domain wiring diagrams: Mermaid structure, behavior, and flow diagrams generated at compile time
- All DSL concepts generate Go code: lifecycle (state constants, predicates, transition validation, default on create, from-constraints on update), queries (prefixed to avoid collisions), specifications (with predicate translation), policies
- Go commands set lifecycle default status on create, enforce from-constraints and set target on update
- Go runtime package: EventBus (goroutine-safe pub/sub with history) and CommandBus (middleware pipeline)
- Go runtime interpreter: `Application` struct boots the domain, wires repos/buses, dispatches commands via `Run(name, json)`, returns `CommandResult` with aggregate + event
- Events published on every command execution, event count live on config page
- Go module registry: domain packages self-register via `init()` for runtime discovery
  - `runtime/registry.go` — thread-safe `Register(ModuleInfo)` and `Modules()` map
  - `register.go` per domain package — `init()` with aggregate/command lists
  - Multi-domain support: each subdomain package gets its own `init()` registration
- Type mapping: String→string, Integer→int64, Float→float64, list_of→[]Type

### Multi-Domain Go Target (HEC-237)
- Each bounded context gets its own Go package (e.g., `pizzas/`, `orders/`)
- Shared runtime package (EventBus, CommandBus) across all domains
- Memory adapters nested under each domain package (`pizzas/adapters/memory/`)
- Single `go.mod` and `cmd/main/main.go` entry point
- `ProjectGenerator` supports `subdomain_mode` for reuse in multi-domain builds

## Node.js/TypeScript Target (`hecks build --target node`)

### Generated TypeScript Project
- TypeScript interfaces for each aggregate with typed fields (id, createdAt, updatedAt)
- Command functions returning typed event objects (create and update patterns)
- Express REST server with GET list, GET by id, and POST command routes per aggregate
- README with getting started instructions

### Type Mapping (via TypeContract registry)
- String -> string, Integer -> number, Float -> number, Boolean -> boolean
- Date/DateTime -> string, JSON -> Record<string, unknown>
- list_of(X) -> X[], reference_to(X) -> string (ID)

### CLI Integration
- Output: `<domain>_static_node/` directory with complete TypeScript project

## Web Explorer Extension (hecks_web_explorer)

### Domain UI as an Extension
- ERB templates for browsing aggregates, executing commands, viewing events
- Renderer class with layout wrapping and HTML escaping

### IR-Driven Structural Discovery (HEC-430)
- All structural queries (aggregate names, attributes, columns, commands, policies, roles) come from the Bluebook IR via `IRIntrospector`
- Runtime CRUD operations (find, all, create, delete) isolated behind `RuntimeBridge`
- No `Object.const_get`, `respond_to?`, or `instance_variable_get` in the UI layer
- Same IR structs consumed by Ruby, Go, and Rails generators now also drive the Web Explorer

### Index Search and Filter (HEC-261)
- Search box on every aggregate index page: `q=` does case-insensitive substring match across all String-typed attributes
- Exact-match filtering via `filter[attr]=value` query params (e.g., `filter[style]=Thin`)
- `IRIntrospector#filterable_attributes` returns String-typed, non-list visible attributes
- `RuntimeBridge#search_and_filter` filters the in-memory collection without custom query classes
- "Clear" link resets to the plain unfiltered index URL

### Event Log Browser (HEC-262)
- Browse all published domain events in a filterable HTML table at `/events`
- `EventIntrospector` reads `EventBus#events` with `all_entries(type_filter:, aggregate_filter:)`, `event_types`, `aggregate_types`
- Filter bar with dropdowns for event type and aggregate type
- Table columns: timestamp, type (badge), aggregate, expandable payload details
- Events displayed in reverse chronological order (newest first)
- `Paginator` provides offset-based pagination (25 per page, prev/next links)
- Content negotiation: `Accept: application/json` returns JSON, otherwise HTML
- "Events" link in the sidebar nav under System group

## Implicit DSL (HEC-229)

### Infer Domain Concepts from Structure
- PascalCase block at domain level → aggregate (`Pizza do ... end`)
- PascalCase block inside aggregate → value object (`Topping do ... end`)
- snake_case block inside aggregate → command (`create do ... end` → CreatePizza)
- Bare `name Type` → attribute (`name String`)
- Command name inference: single verb + aggregate name, multi-word as-is
- Same IR output — implicit is sugar on top of explicit DSL
- Both forms can be mixed in the same file

## Testing

### Cross-Target Parity
- Builds Pizzas domain into both Ruby static and Go targets from the domain IR
- Boots both HTTP servers, submits identical command sequences via browser-style form submission

### Rails Smoke Test
- `hecksties/spec/rails_smoke_spec.rb` — tagged `:slow`, excluded from default run
- Boots `examples/pizzas_rails` as a real subprocess against a free port
- Exercises full CRUD lifecycle: index, new, create, show, edit, update, destroy
- Validates 422 on invalid params via ActiveModel validations

### FEATURES.md Audit (`tools/features_audit.py`)
- Cross-references every bullet in `FEATURES.md` against the codebase so the claim-list cannot drift silently
- Parses one claim per bullet, extracts backticked code, PascalCase tokens, `Namespaced::Names`, dotted calls (`Hecks.configure`), and `:symbols`, then greps across `lib/`, `hecks_life/src/`, `hecks_conception/aggregates/`, `hecks_conception/capabilities/`, `spec/`, `examples/`, `bin/`, `.claude/` (docs are excluded to avoid circular evidence)
- Three buckets per claim: **verified** (at least one identifier resolves), **missing** (identifiers present but none found — real drift), **unverifiable** (pure prose)
- Fallbacks: `Foo.bar` tokens check for `def self.bar` in files containing `Foo`; lowercase-head tokens check for `def <method>`; placeholder patterns (`<Some>Domain`, `model.foo?`, `.md` links) are stripped
- CLI flags: `--missing` lists every drift with its searched identifiers, `--section "Name"` scopes to one heading, `--json` for machine-readable output
- Works in tandem with the reader's-guide banner at the top of `FEATURES.md` — audit answers "does this identifier still exist?", `hecks verify` answers "is it still tested?"
- Baseline: 0 missing across 702 claims; the antibody is simple — if `missing` > 0, something was claimed without evidence

## Event Sourcing (Phase 3)

### Optimistic Concurrency (HEC-65)
- Version stamping on aggregates via `Concurrency.stamp!(aggregate, version)`

### CQRS Read Model Store (HEC-63)
- Memory adapter for tests; swappable for Redis/SQL in production

### Event Versioning & Upcasting (HEC-70)
- `UpcasterRegistry` for registering schema migrations per event type
- `UpcasterEngine` chains upcasters from stored schema_version to latest
- Transparent upcasting on read — events stored at any version are automatically transformed

### Read Models / Projections (HEC-64)
- `EventStore` with append-only streams, auto-versioning, and global position ordering
- `ProjectionRebuilder` replays events through projection procs to rebuild read model state
- Integrates with `UpcasterEngine` for transparent upcasting during rebuild

### Outbox Pattern (HEC-80)
- `Outbox` port with store/pending/mark_published/published
- `OutboxPoller` publishes pending events to the event bus (one-shot or background thread)

### Process Managers (HEC-67)
- `ProcessManager` event-driven state machine with correlation-based instance lookup
- Action blocks can return `{ commands: [...] }` for dispatching
- Subscribes to `EventBus` for automatic event handling

### Aggregate Snapshots (HEC-69)
- `SnapshotStore` port with save/load/delete/clear
- `Reconstitution` rebuilds aggregate state from snapshot + subsequent events
- Auto-snapshot at configurable intervals (e.g., every N events)
- Applier hash maps event types to state-transform procs

### Time Travel (HEC-98)
- `TimeTravel#as_of(stream_id, timestamp, appliers)` returns state at a point in time
- `TimeTravel#at_version(stream_id, version, appliers)` returns state at a specific version
- Built on `EventStore#read_stream_until` and `read_stream_to_version`

## Domain-Driven Web Applications
- **Nursery web apps** — static HTML/CSS/JS applications generated from Bluebook domains with full domain tagging
- Domain tags on every element: `data-domain-aggregate`, `data-domain-command`, `data-domain-attribute`
- Brand switcher: CSS custom property theming driven by bounded context data
- Cross-domain policies rendered as UI connections (e.g., SDS links from compliance, Prop 65 from regulatory_compliance)
- Alan's Engine Additive Business: 16 bounded contexts, 9 pages, 491 domain-tagged elements, 3 brand themes
- Dark-themed Tailwind UI with sidebar navigation, dashboard metrics, domain detail pages with module cards, command forms, and fixture tables
- **Workflow pipeline UI** — aggregates with a `lifecycle` render as a horizontal step pipeline (default state highlighted in gold, arrows between steps, commands grouped under their target state)
- **Per-module fixture tables** — fixture records display inline inside each module card on the Build tab, filtered by aggregate name
- **Invariant gating on workflow steps** — commands with `givens` (preconditions) appear dimmed on their workflow step with the precondition expression shown in amber
- Command forms submit via fetch to the JSON dispatch endpoint — no page reload, inline success/error feedback
- Domain tags (`data-domain-aggregate`, `data-domain-command`) on all generated HTML elements

## Examples
- Pizzas domain: plain Ruby app with commands, queries, collection proxies, event history
- Pizzas static Ruby: generated standalone Ruby project with HTTP server, UI, roles, filesystem persistence
- Pizzas static Go: generated Go project with HTTP server, memory adapters, same domain
- Spaghetti Western: Rails-imported domain (gunslingers, duels, bounties, saloons) — demonstrates reverse-engineered DDD from ActiveRecord
- Governance: 5 bounded contexts (compliance, model registry, operations, identity, risk assessment) — 930 lines of DSL exercising every concept

## Aspirational (not yet tested)

> Features below were claimed in earlier revisions but have no discoverable
> backing test or behavior in `spec/`, `hecks_life/tests/`,
> `hecks_conception/tests/`, `.behaviors`, or `.fixtures`. They may still
> work — they just aren't locked down by a test today. As tests land,
> move the line back up into the main body above.

### Domain Modeling DSL

**Core Structure**

- `Hecks.configure { chapter "x" }` — chapter alias for domain in configuration DSL

**Sagas / Process Managers**

- Automatic compensation on failure: reverses completed steps in reverse order (best-effort)
- Compensations are rollback commands run in reverse order if the saga must unwind

**Ubiquitous Language**

- `glossary { prefer "customer", not: ["user", "client"] }` — warn when banned terms appear in names across aggregates, commands, and events
- `glossary { define "aggregate", as: "A cluster of objects" }` — define domain terms for the glossary

**World Concerns**

- `world_concerns :transparency, :consent, :privacy, :security` — opt-in ethical validation rules
- `:transparency` — commands must emit events (no silent mutations)
- `:consent` — user-like aggregate commands must declare actors
- `:privacy` — PII attributes must be `visible: false`; PII aggregate commands need actors
- `:security` — command actors must be declared at domain level
- GovernanceGuard falls back to rule-based checks when no LLM API key is present; enriches suggestions via AI when available

### Extensions

**Extension Registry**

- Add to Gemfile to wire, remove to unwire — no code changes needed

**Persistence Extensions**

- `hecks_sqlite` — SQLite persistence, auto-wires when in Gemfile
- `hecks_postgres` — PostgreSQL persistence
- `hecks_mysql` — MySQL persistence
- `hecks_mongodb` — MongoDB persistence; value objects embedded as nested documents (no join tables)
- `hecks_cqrs` — named persistence connections for read/write separation
- `hecks_mongodb` — MongoDB document persistence via the mongo Ruby driver

**Server Extensions**

- `hecks_serve` registers `:http` — adds `CatsDomain.serve(port: 9292)`
- `hecks_ai` registers `:mcp` — adds `CatsDomain.mcp`

**Application Service Extensions**

- `hecks_auth` — actor-based authentication & authorization
- Session management via HttpOnly cookies with Base64-encoded JSON payloads
- `hecks_tenancy` — multi-tenant isolation (`Hecks.tenant = "acme"`)
- `Hecks.current_user` / `Hecks.with_user(user) { }` — thread-local current user context for ownership enforcement
- `hecks_audit` — audit trail of every command execution
- `hecks_logging` — structured stdout logging with duration
- `hecks_rate_limit` — sliding window rate limiting per actor
- `hecks_idempotency` — command deduplication by fingerprint
- `hecks_transactions` — DB transaction wrapping when SQL adapter present
- `hecks_retry` — exponential backoff for transient errors

**Domain Connections DSL**

- `extend :slack, webhook: url` — forward all domain events to an outbound handler
- `extend(:audit) { |event| ... }` — forward events to a block handler
- `extend CommentsDomain` — subscribe to another domain's event bus (cross-domain events)
- `extend :tenancy` — add middleware extension
- `SomeDomain.connections` — inspect current connection configuration
- `SomeDomain.event_bus` — access the domain's event bus for cross-domain wiring
- `Runtime#swap_adapter(name, repo)` — extension gems swap memory adapters for SQL

### Capabilities

- `app.capability(:crud)` — generate Create, Update, Delete command stubs for all aggregates; skips user-defined commands
- `hecks new` app.rb scaffold includes `app.capability(:crud)` by default

**Parity Suite**

- **CI gate** — `.github/workflows/parity.yml` runs the suite on every PR.

### Shebang Scripts (hecks-life run)

**Companion hecksagon**

- `<stem>.hecksagon` sibling is auto-loaded for adapter wiring
- `gate "Aggregate", :role do allow :Cmd end` — role-based gates
- `subscribe "OtherDomain"` — cross-domain event wiring

### Runtime API

- `app["Pizza"]` — access aggregate repository
- `app.events` — event history
- `app.async { }` — register async handler for policies and subscribers
- `app.use { }` — register command bus middleware
- `enable "Aggregate", :versioned` — enable version tracking (infrastructure config, not domain IR)
- `enable "Aggregate", :attachable` — enable file attachment support (infrastructure config, not domain IR)
- `Hecks.shared_event_bus` — access the shared cross-domain event bus after multi-domain boot

### Code Generation

**Generation Features**

- Stacked codegen: constructors stack one-per-line when >2 args
- CalVer versioning (YYYY.MM.DD.N) auto-assigned at build time

**Self-Hosting Analysis**

- `hecks self_diff <chapter>` — compares what generators would produce from a chapter's Domain IR against the actual gem code
- `hecks self_diff <chapter> --framework` — framework skeleton mode, generates method stubs + doc comments from IR, matches against actual files by name
- Classifies every file as match, partial, uncovered, or extra with line overlap percentages

**CLI (hecks_cli)**

- Aggregate commands become CLI verbs via the runtime command bus (e.g. `hecks pizzas create-pizza --name X`)

**Self-Hosting DSL Extensions**

- `inherits "Hecks::Generator"` — declares superclass for class-kind aggregates
- `method_name "sql_type_for"` — overrides auto-generated method name on commands (default: snake_case of command name)
- `entry_point "hecks_persist"` — declares autoload entry point files for the domain

### HecksUL Language Specification

- `HecksUL.syntax` — 58 keywords across 5 contexts (domain, aggregate, command, value_object, entity)
- `HecksUL.describe` — prints a human-readable summary of the entire language

### Persistence

- PStore adapter — file-based object store using Ruby stdlib, zero dependencies, supports query with conditions/ordering/pagination
- SQL adapter via Sequel ORM supporting MySQL, PostgreSQL, and SQLite
- Automatic reference resolution with lazy loading from repository

### Querying

- `where(field: value)` filtering on aggregates
- `find_by(field: value)` for single-record lookup
- `exists?` check without loading all records
- `pluck(:name)` for attribute-only results
- Aggregations: `sum(:price)`, `min(:price)`, `max(:price)`, `average(:price)`
- Named scopes callable as class methods
- Ad-hoc query support via `include_ad_hoc_queries` config

### Command & Event System

- Class-level command methods: `Pizza.create(name: "M")`
- `Hecks::Command` mixin orchestrates full lifecycle (guard → handler → call → persist → emit → record)
- `Hecks::Query` mixin — queries are self-contained like commands
- In-process event bus with subscriptions and wildcard `on_any`
- Async subscriber and policy dispatch via configurable `async { }` block

### Smalltalk-Inspired REPL

**Sketch & Play**

- Interactive session for incremental domain building (`Hecks.session`)
- `sketch!` / `play!` toggling — switch between modeling and execution modes
- `reload!` — re-read the domain DSL and reboot the playground without leaving play mode; clears events and data

**One-Line Dot Syntax**

- Command attribute chaining: `Post.create.title String` adds attribute to command
- Terse single-line feedback after every operation (e.g. "title attribute added to Post")

**Architecture Tour**

- Contributor walkthrough via `hecks tour --architecture` — 10-step tour of framework internals

**Web Console**

- Interactive domain diagram with aggregate nodes, reference arrows, and policy flow visualization

**Session Features**

- `handle.build(**attrs)` — compile domain and return a live domain object
- `promote("Comments")` — extract aggregate into its own standalone domain file
- `extend :logging` — apply extensions to live runtime without rebooting
- Session image save/restore: `save_image` / `restore_image` to snapshot and restore workshop state
- Named image labels: `save_image("checkpoint")` for multiple save points
- `list_images` to see all saved session snapshots
- `Hecks::TestHelper` for spec setup and constant cleanup

### Validation & DDD Rules

- Command names must be verb phrases (WordNet + custom verbs)
- Reactive policy events and triggers must reference existing elements

**Lifecycle Validator (`hecks-life check-lifecycle`)**

- `--strict` promotes warnings to errors; pre-commit hook blocks on errors

**IO Validator (`hecks-life check-io`)**

- `hecks-life check-all` runs lifecycle + IO together

**Behavioral Tests (`hecks-life conceive-behaviors` + `behaviors`)**

- Skips tests for non-equality givens that the chain planner can't auto-satisfy

### Domain Interface Versioning

- `hecks version_tag <version>` — snapshot current domain DSL to `db/hecks_versions/<version>.rb` with metadata header
- `hecks version_log` — list all tagged versions newest-first with date and one-line change summary
- `hecks diff --v1 <v1> --v2 <v2>` — diff two tagged version snapshots with breaking change classification
- `hecks diff --v1 <v1>` — diff a tagged version against the working domain file
- `hecks diff` — diff working domain against latest tagged version (falls back to build snapshot)

### Documentation Generation

- README generator with `{{tags}}` for auto-generated sections
- `{{connections}}` tag generates extension gem listing
- `{{smalltalk}}` tag generates Smalltalk features section from `SmalltalkFeatures` metadata

### AST-Based Domain Extraction (HEC-476)

- Extracts: domain name, aggregates, attributes (with types, list, defaults), commands, references, value objects, entities, validations, specifications, queries, invariants, scopes, domain-level policies (with attribute maps), services, world goals, actors, sagas, modules, workflows, views

### Gem Architecture

- Hexagonal / ports-and-adapters: domain layer has zero persistence knowledge

**Module Infrastructure (hecks_modules)**

- `Hecks::ModuleDSL` — declarative `lazy_registry` for defining lazily-initialized registries
- All registries (targets, adapters, extensions, domains, dump formats, validations) use `lazy_registry`
- `Hecks::CoreExtensions` — namespace for Ruby core class extensions

**Deprecation System (hecks_deprecations)**

- `HecksDeprecations.register(target_class, method_name) { ... }` — register deprecated shims
- `HecksDeprecations.registered` — introspect all registered deprecations

**Rails Import (Reverse Engineering)**

- `hecks import rails /path/to/app` — extract domain from existing Rails app
- `hecks import schema /path/to/schema.rb` — schema-only import
- `hecks extract /path/to/project` — auto-detect project type and extract domain
- `Hecks::Import.from_directory(path)` — programmatic auto-detecting extraction
- `Hecks::Import.from_models(models_dir)` — programmatic model-only extraction
- Parses db/schema.rb: tables → aggregates, columns → typed attributes, foreign keys → references
- Parses app/models: validates → validations, enum → enum constraints, AASM → lifecycles
- Skips Rails internal tables (schema_migrations, active_storage_*, etc.)

### Autophagy: Self-Hosting Compiler (Hecks v0)

- `hecks compile` — compile the entire Hecks framework into a single self-contained Ruby script
- `hecks compile --plan` — show compilation plan (file count and list) without writing
- `hecks compile --output NAME` — specify output file name (default: `hecks_v0`)
- `hecks compile --trace` — emit auditable trace of every compiler decision to stderr
- Injects forward declarations for load-order dependencies
- Pre-registers all bundled files in `$LOADED_FEATURES` to prevent double-loading

### Runtime Code Generation

- Generators replace only the orchestration loops — same behavior, no runtime IR traversal

### CLI Commands

- `hecks build` — validate and generate versioned gem
- `hecks serve [--rpc]` — start REST or JSON-RPC server
- `hecks serve --watch` — hot reload: polls domain source for changes and rebuilds routes without restart
- `hecks validate` — check domain against DDD rules
- `hecks mcp` — start MCP server
- `hecks inspect` — show full domain definition including business logic (attributes, lifecycle, commands, policies, invariants, etc.)
- `hecks glossary` — print domain glossary to stdout; `--export` writes `glossary.md`
- `hecks dump` — show glossary, visualizer, and DSL output
- `hecks migrations` — schema migration management
- `hecks docs update` — sync doc headers and READMEs
- All commands accept `--domain` flag consistently

### Rails Integration (ActiveHecks)

- `Hecks.configure` block for Rails initializers
- `to_param` patched on command results — URL helpers work naturally
- `rails generate active_hecks:live` — standalone live event setup
- `rails generate active_hecks:migration` — SQL migrations from domain changes

### HecksLive — Real-Time Domain Events

- Views just need `<%= turbo_stream_from "hecks_live_events" %>` and `<div id="event-feed">`
- No custom JavaScript — standard Rails Turbo Streams
- Stdout fallback when ActionCable is not available (plain Ruby apps)

### Module Structure (HEC-370)

- `hecksties/` — core kernel: registries, errors, autoloads, utilities, version
- `hecks_templating/` — naming helpers + data contracts (type, view, event, migration, UI label)
- `hecks_runtime/` — command bus, ports, middleware, extensions, boot
- `hecks_features/` — vertical slice extraction, leaky slice detection, slice diagrams
- Standalone: heksagons, hecks_workshop, hecks_cli, hecks_static, hecks_on_the_go, hecks_persist, hecks_watchers

### AI-Native

**llms.txt Generation**

- `hecks llms` generates AI-readable domain summary with aggregates, commands, types, policies, flows
- `hecks build` includes `llms.txt` in every generated domain gem for automatic agent discovery
- Covers attributes with types, commands with parameters, validation rules, invariants, reactive chains

**MCP Server**

- MCP-compatible runtime boots domains from IR without gem building — no disk I/O, no tmpdir, no `Hecks.build`
- `execute_command` MCP tool auto-enters play mode if not already active — removes a round-trip
- `Workshop#execute` delegates to the playground and auto-enters play mode when needed
- `hecks mcp` exposes all domain commands, queries, and repository operations as typed MCP tools
- `describe_domain` tool returns the entire domain model as structured JSON in one call
- `add_lifecycle` and `add_transition` tools for state machine building via MCP
- `add_attribute` tool for adding individual attributes to existing aggregates

**Command Bus Port (HTTP Adapter Boundary)**

- `Hecks::HTTP::CommandBusPort` — explicit port between HTTP routes and the domain

**Self-Discoverable HTTP API**

- `GET /_openapi` returns the OpenAPI 3.0 spec as JSON

**Claude Code Integration**

- `hecks claude` starts background file watchers, then launches Claude Code with `--dangerously-skip-permissions`
- `bin/pre-commit` runs the watcher suite as a commit gate (blocking on cross-require failures, advisory on the rest)
- `bin/read-watcher-log` is the script the hook runs

**Watcher Agent (hecks_watcher_agent)**

- `hecks fix-watchers` reads watcher log and creates PRs to fix issues
- Hybrid fix engine: pure Ruby for simple fixes, Claude Code for complex ones
- Claude Code fixes: file size extraction, doc updates (FEATURES.md, CHANGELOG)

**Gem Packaging**

- `hecks gem install` builds, installs, and cleans up all component gems in dependency order
- Stops on first failure rather than continuing with a broken build

**Domain Flow Generation**

- Included in `domain.describe` output and `hecks dump`

**Domain Serialization**

- `DomainSerializer.call(domain)` returns complete domain as structured Hash/JSON

### Static Domain Generation (hecks_static)

**Zero-Dependency Output — Full DSL Parity**

- `hecks build --static` generates a complete Ruby project with no hecks runtime dependency
- `bin/<domain> serve` starts an HTTP server with JSON API and HTML UI
- `bin/<domain> console` opens IRB with the domain loaded
- `bin/<domain> generate` regenerates domain code from `hecks_domain.rb`
- `bin/<domain> info` shows config, aggregates, ports, policies

**HTTP Server & UI**

- WEBrick-based server with JSON API (one POST per command, GET per aggregate)
- OpenAPI endpoint at `/_openapi`, validation rules at `/_validations`
- `GET /_events` — JSON event log (EventLogContract shape, same for Ruby and Go)
- `POST /_reset` — clear all data (button on config page, used by smoke tests)

**Port-Based Access Control**

- `check_port_access` runs in Command lifecycle before guards/preconditions

**Validation (hecks_validations extension)**

- Extracts validation rules from domain IR at build time
- `/_validations` JSON endpoint serves rules to clients

**Project Structure**

- `hecks_domain.rb` — domain DSL (source of truth, regeneratable)
- `boot.rb` — wiring (stable, written once, not regenerated)
- `bin/<domain>` — CLI entry point

### Extensions

**hecks_filesystem_store**

- `gem "hecks_filesystem_store"` auto-wires at boot

**hecks_validations**

- Provides `validate_params` method and `validation_rules` on domain module
- Wires into command bus as middleware

### Go Domain Generation (hecks_go)

**Go Output from Same DSL**

- `Hecks.build_go(domain)` generates a complete Go project from the same domain IR
- Aggregate structs with `Validate()` method from DSL validations
- Command structs with `Execute(repo)` returning `(*Aggregate, *Event, error)`
- HTTP server using `net/http` (JSON API with POST per command, GET per aggregate)
- Go `html/template` views generated from ERB at build time — ERB is single source of truth
- Go aggregate `Validate()` enforces enum constraints from AggregateContract
- `go.mod` with only `google/uuid` dependency

**Multi-Domain Go Target (HEC-237)**

- `Hecks.build_go_multi(domains)` generates a multi-domain Go project
- Combined server routing all domain aggregates under `/<domain>/<aggregate>` prefix

### Node.js/TypeScript Target (`hecks build --target node`)

**Generated TypeScript Project**

- In-memory repository classes using `Map<string, T>` with all(), find(), save(), delete()
- `package.json` with express, typescript, ts-node, @types/express
- `tsconfig.json` with ESNext module, strict mode, ES2022 target

**CLI Integration**

- `hecks build --target node` registered in target registry

### Web Explorer Extension (hecks_web_explorer)

**Domain UI as an Extension**

- Templates shared between Ruby static and Go targets
- Views: layout, home, index, show, form, config
- Registers with runtime, auto-wires when loaded

### Implicit DSL (HEC-229)

**Infer Domain Concepts from Structure**

- `ref("X")` alias for `reference_to("X")`
- `port :name, [methods]` compact inline form

### Testing

**Cross-Target Parity**

- `hecksties/spec/cross_target_parity_spec.rb` — tagged `:parity`, excluded from default run
- Fetches `/_events` from both, normalizes to event name lists, asserts equality
- Run explicitly: `bundle exec rspec hecksties/spec/cross_target_parity_spec.rb --tag parity`

**Rails Smoke Test**

- Run explicitly: `bundle exec rspec hecksties/spec/rails_smoke_spec.rb --tag slow`

### Event Sourcing (Phase 3)

**Optimistic Concurrency (HEC-65)**

- `ConcurrencyError` raised on version mismatch
- `VersionCheckStep` lifecycle step for commands with `expected_version`

**CQRS Read Model Store (HEC-63)**

- `ReadModelStore` port with thread-safe get/put/delete/clear/keys

**Read Models / Projections (HEC-64)**

- Supports rebuilding from all events or a single stream

**Outbox Pattern (HEC-80)**

- `OutboxStep` replaces `EmitStep` in the command lifecycle for transactional event capture
- Guarantees at-least-once event delivery

**Process Managers (HEC-67)**

- Supports state transitions with `on(event_type, correlate:, transition:)` DSL

### Domain-Driven Web Applications

- **hecks-life serve generates full Tailwind web app** — `hecks-life serve path/to/hecks/ 3100` serves both JSON API and HTML UI from the same port
- **Contextual help icons** — every module card and command has a ? button that opens a help popup built from domain tags (aggregate name, description, field list, record/action counts)

### Examples

- Rails pizza shop: full Turbo Streams app with admin, ordering, toppings, pricing, live events
- Banking domain: 4 aggregates, cross-aggregate policies, specifications, entities, SQLite

