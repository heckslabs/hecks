# Hecks Framework — Feature List

> **Reader's guide.** This file is the claim-list — a curated record of
> features as they were introduced. It is not the source of truth for what
> is currently verified by tests. Some entries describe shipped + tested
> behavior; others describe work whose tests have since moved, been
> rewritten, or lag behind the prose.
>
> For **what is actually exercised right now**, run:
>
> ```
> hecks verify
> ```
>
> That walks the contract suite, parity suite, and behavioral tests and
> reports pass/fail per area. Anything not covered by `hecks verify` should
> be read as "claimed" until the audit backfills a test link per line.
>
> The audit is tracked in the living inbox as a follow-up to this banner.

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
- **Self-hosting** — Hecks generates itself from its own Bluebook chapters. All 16+ chapters (Bootstrap, Bluebook, Kernel, Runtime, Binding, CLI, Extensions, Targets, Workshop, Hecksagon, AI, Rails, Spec, Templating, Watchers, Persist, Examples) boot as running Hecks applications via `InMemoryLoader` + `Runtime`. 743 aggregates, 932 commands.
- **Bootstrap chapter** — `Hecks::Chapters::Bootstrap` describes the bootstrap kernel (DSL builders, domain model IR, tokenizer, chapter system) as aggregates. The bridge between Stage 0 (interpreted) and Stage 1 (compiled / Hecks v0).
- **Kernel chapter** — Descriptive Bluebook chapter covering registries, core utilities, and the chapter system itself.
- **Self-compile manifest** — `Hecks::SelfCompile` lists all chapters in load order with `summary`, `total_aggregates`, `total_commands`, and `missing_chapters` introspection methods. Proves the Bluebook is a complete specification of Hecks.
- **Coverage verification** — `CoverageVerifier` walks all `.rb` files in `lib/` and checks each is covered by at least one chapter aggregate. Integrated into `bin/verify` as Phase 4.
- **Paragraphs** — `paragraph "Ports" { aggregate "EventBus" do ... end }` groups aggregates into named sections within a chapter. Paragraphs are first-class IR nodes (`Structure::Paragraph`) tracked on the domain, enabling organizational splitting without creating separate domains.
- **Bluebook glossary** — `bluebook.glossary` prints the Ubiquitous Language for the entire composed system, walking binding + all chapters and listing every aggregate and command with descriptions.
- Workshop chapter mode — define and play multiple chapters interactively with `workshop.chapter("Name") { ... }`
- `Hecks.configure { chapter "x" }` — chapter alias for domain in configuration DSL
- Domain version pinning and local path loading in configuration

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
- Automatic compensation on failure: reverses completed steps in reverse order (best-effort)
- Timeout and on_timeout metadata for time-bounded sagas
- In-memory `SagaStore` for saga instance persistence (swappable for Redis/SQL)
- `SagaRunner` state machine: pending -> running -> compensating -> completed/failed
- Wired as `start_<saga_name>` methods on the domain module: `OrdersDomain.start_order_fulfillment(...)`
- Steps declare success and failure transitions to other named commands
- Compensations are rollback commands run in reverse order if the saga must unwind
- Saga definitions stored in domain IR and available via `domain.sagas`

### Ubiquitous Language
- `glossary { prefer "customer", not: ["user", "client"] }` — warn when banned terms appear in names across aggregates, commands, and events
- `glossary { define "aggregate", as: "A cluster of objects" }` — define domain terms for the glossary
- `prefer` accepts optional `definition:` kwarg to document preferred terms inline
- Glossary `generate` produces a "Ubiquitous Language" section with definitions and avoid lists

### World Concerns
- `world_concerns :transparency, :consent, :privacy, :security` — opt-in ethical validation rules
- `:transparency` — commands must emit events (no silent mutations)
- `:consent` — user-like aggregate commands must declare actors
- `:privacy` — PII attributes must be `visible: false`; PII aggregate commands need actors
- `:security` — command actors must be declared at domain level
- **World Concerns Report** — `hecks validate` shows a per-concern PASS/FAIL summary with violations listed
- **GovernanceGuard** — general-purpose governance checker (`Hecks::GovernanceGuard.new(domain).check`) returns `Result` with `passed?`, `violations`, `suggestions`; works from CLI (`--governance`), MCP (`governance_check` tool), REPL, or any entry point
- GovernanceGuard falls back to rule-based checks when no LLM API key is present; enriches suggestions via AI when available

### Access Control & Ports
- Define access-control ports that whitelist allowed methods per consumer
- Import domains from event storm formats (Markdown and YAML)

## Extensions

### Extension Registry
- Extension registry: `Hecks.register_extension(:sqlite) { |mod, domain, runtime| ... }`
- Add to Gemfile to wire, remove to unwire — no code changes needed
- Adapter type classification: `adapter_type: :driven` or `:driving` on `describe_extension`
- Two-phase boot: driven extensions (repos, middleware) fire before driving extensions (HTTP, queues)
- Query helpers: `Hecks.driven_extensions` and `Hecks.driving_extensions`
- Extension aliasing: `Hecks.alias_extension(:short, :long)` registers a shorthand key for an existing extension
- Standard extension format: describe, register, namespace under `Hecks::` (e.g. `Hecks::Audit`, `Hecks::PII`, `Hecks::Queue`)
- Every extension declares its config keys in `describe_extension` for introspection
- Every extension has a "Future gem" comment documenting its intended gem name

### Persistence Extensions
- `hecks_sqlite` — SQLite persistence, auto-wires when in Gemfile
- `hecks_postgres` — PostgreSQL persistence
- `hecks_mysql` — MySQL persistence
- `hecks_mongodb` — MongoDB persistence; value objects embedded as nested documents (no join tables)
- `hecks_cqrs` — named persistence connections for read/write separation
- `hecks_mongodb` — MongoDB document persistence via the mongo Ruby driver

### Server Extensions
- `hecks_serve` registers `:http` — adds `CatsDomain.serve(port: 9292)`
- `hecks_ai` registers `:mcp` — adds `CatsDomain.mcp`

### Application Service Extensions
- `hecks_auth` — actor-based authentication & authorization
- Default-secure auth: raises `ConfigurationError` at boot when actor-protected commands exist but no `:auth` extension is registered
- Explicit opt-out: `extend :auth, enforce: false` registers a no-op sentinel that satisfies the check
- Auth screens: auto-generated login/signup/logout HTML pages wired into the serve extension (GET/POST `/login`, GET/POST `/signup`, GET `/logout`)
- Session management via HttpOnly cookies with Base64-encoded JSON payloads
- In-memory credential store for development; default role inferred from domain DSL actor declarations
- `hecks_tenancy` — multi-tenant isolation (`Hecks.tenant = "acme"`)
- Row-level authorization — `owned_by :field` on gates restricts `find`/`all`/`delete` to the current user; `tenancy: :row` isolates by `Hecks.tenant`
- `Hecks.current_user` / `Hecks.with_user(user) { }` — thread-local current user context for ownership enforcement
- `hecks_audit` — audit trail of every command execution
- `hecks_metrics` — change tracking for metric-tagged aggregate attributes; `Hecks.metric_log` in-memory log; `Hecks.metric_sink=` pluggable sink for StatsD/Prometheus; `capability.login_count.metric` DSL tag in Hecksagon
- `hecks_logging` — structured stdout logging with duration
- `hecks_rate_limit` — sliding window rate limiting per actor
- `hecks_idempotency` — command deduplication by fingerprint
- `hecks_transactions` — DB transaction wrapping when SQL adapter present
- `hecks_retry` — exponential backoff for transient errors
- `hecks_bubble` — anti-corruption layer (ACL) for legacy data translation; context DSL with `map_aggregate`, `from_legacy` (field renaming + transforms), `map_out` (reverse mapping); API: `context.translate(:Pizza, :create, legacy_data)` and `context.reverse(:Pizza, :create, domain_data)`

### Domain Connections DSL
- `extend :sqlite` — declare persistence adapter
- `extend :slack, webhook: url` — forward all domain events to an outbound handler
- `extend(:audit) { |event| ... }` — forward events to a block handler
- `extend CommentsDomain` — subscribe to another domain's event bus (cross-domain events)
- `extend :tenancy` — add middleware extension
- `extend :sqlite, as: :write` — named CQRS connections
- `SomeDomain.connections` — inspect current connection configuration
- `SomeDomain.event_bus` — access the domain's event bus for cross-domain wiring
- `Runtime#swap_adapter(name, repo)` — extension gems swap memory adapters for SQL

## Capabilities
- `app.capability(:crud)` — generate Create, Update, Delete command stubs for all aggregates; skips user-defined commands
- Capability registry: `Hecks.register_capability(:name) { |runtime| ... }` — plug in custom capabilities
- CRUD capability auto-enabled in Workshop play mode and Rails (`Hecks.configure`)
- `hecks new` app.rb scaffold includes `app.capability(:crud)` by default

### Bluebook Capabilities (Miette)
- **ProjectManagement** — replaces Linear for tracking features, sprints, priorities, dependencies, milestones, and work logs. Features are domain-aware via DomainLink — every feature links to a bluebook domain. Stored in heki, queryable by Miette. 7 aggregates, 3 policies, seeded with current Linear issues.
- **DLMState** — the DLM tracks itself in Heki. SessionState, GrowthTracker, HonestyTracker, DreamLog, PerformanceMetric, SynapseHistory — 6 aggregates, 18 commands, 5 cross-domain policies. Acceleration rate measures domains conceived per session. Persists across sleep cycles.

### Parity Suite
- **Ruby ↔ Rust IR conformance** — `spec/parity/parity_test.rb` runs every fixture through both parsers (Ruby DSL + hecks-life), converts each output to a canonical JSON shape, and diffs. 43/43 baseline (13 synthetic fixtures + 30 real bluebooks).
- **Canonical shape contract** — hand-written on both sides (`hecks_life/src/dump.rs` + `spec/parity/canonical_ir.rb`). The JSON shape IS the contract, not auto-derived.
- **`hecks-life dump <file.bluebook>`** — emits canonical JSON IR. Same shape the Ruby canonicalizer produces.
- **Known-drift list** — `spec/parity/known_drift.txt` documents expected disagreements (currently empty). Fixtures listed here report ⚠ instead of blocking; if a known-drift file starts passing, the suite reports ⚑ and tells you to remove the line.
- **Pre-commit gate** — `bin/git-hooks/pre-commit` blocks unexpected drift in ~1 second. Install with `bin/install-hooks`.
- **CI gate** — `.github/workflows/parity.yml` runs the suite on every PR.
- **Self-description** — `aggregates/bluebook.bluebook` declares the IR shape both parsers must produce (13 aggregates, one per IR concept: Domain, Aggregate, Attribute, ValueObject, Reference, Command, Query, Given, Mutation, Lifecycle, Transition, Policy, Fixture).

## Runtime API
- `Hecks.boot(__dir__)` — find domain file, validate, build, load, and wire in one call
- `Hecks.boot(__dir__, adapter: :sqlite)` — automatic SQL setup
- `Hecks.boot(__dir__) { extend :sqlite }` — boot block with connections
- `Hecks.load(domain)` — load domain and wire runtime in one step
- `app["Pizza"]` — access aggregate repository
- `app.on("EventName") { }` — subscribe to events at runtime
- `app.run("CommandName", attrs)` — dispatch commands
- `app.events` — event history
- `app.async { }` — register async handler for policies and subscribers
- `app.use { }` — register command bus middleware
- `enable "Aggregate", :versioned` — enable version tracking (infrastructure config, not domain IR)
- `enable "Aggregate", :attachable` — enable file attachment support (infrastructure config, not domain IR)
- `Hecks.boot(__dir__)` auto-detects multi-domain when `bluebook/` has multiple Bluebook files
- `Hecks.shared_event_bus` — access the shared cross-domain event bus after multi-domain boot
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
- Stacked codegen: constructors stack one-per-line when >2 args
- Port enforcement stubs, autoload registries, gem scaffolds
- Preview generated source for any aggregate without writing files
- Auto-include mixins by convention — `include Hecks::Command` in generated files
- Auto-generate OpenAPI, JSON-RPC discovery, JSON Schema, TypeScript types (.d.ts), and glossary docs on build
- TypeScript type generation — interfaces for aggregates/value objects/entities, types for commands/events, enums for lifecycles, union types for enums; `hecks dump --types` for standalone export
- Preserve custom `call` methods on regenerate
- CalVer versioning (YYYY.MM.DD.N) auto-assigned at build time
- Resolve domains from installed gems, not just local files

### Self-Hosting Analysis
- `hecks self_diff <chapter>` — compares what generators would produce from a chapter's Domain IR against the actual gem code
- `hecks self_diff <chapter> --framework` — framework skeleton mode, generates method stubs + doc comments from IR, matches against actual files by name
- `FrameworkGemGenerator` — locates actual files by aggregate name, generates skeletons with correct module nesting and method stubs from commands
- Classifies every file as match, partial, uncovered, or extra with line overlap percentages
- Programmatic API via `SelfHostDiff.new(domain, gem_root:, mode: :framework).summary`
- Hecksagon baseline: 93.3% coverage (28/30 files have partial matches from IR-derived skeletons)

### Chapter CLI Generation
- `CliGenerator` — generates Thor CLI subcommands from any Bluebook chapter definition
- Aggregate commands become CLI verbs: `CreatePizza` -> `create_pizza --name X`
- IR attribute types map to Thor option types (String->:string, Integer->:numeric, etc.)
- Automatic collision handling: prefixes aggregate name when verbs overlap across aggregates
- `build_thor_class` — evaluates generated source into a live Thor class for immediate use
- Works with any chapter — not coupled to a specific domain
- Optional `namespace:` wraps output in a Ruby module

### Self-Hosting DSL Extensions
- `namespace "Hecksagon::DSL"` — declares the module nesting for an aggregate, used by skeleton generator
- `inherits "Hecks::Generator"` — declares superclass for class-kind aggregates
- `includes "SqlBuilder"` — declares module mixins included in the aggregate
- `method_name "sql_type_for"` — overrides auto-generated method name on commands (default: snake_case of command name)
- `entry_point "hecks_persist"` — declares autoload entry point files for the domain

## HecksUL Language Specification
- `HecksUL` (Ubiquitous Language) — every Hecks domain is its own executable business language
- `HecksUL.syntax` — 58 keywords across 5 contexts (domain, aggregate, command, value_object, entity)
- `HecksUL.compiler` — Bluebook DSL frontend, DomainModel IR, multiple backends
- `HecksUL.self_hosting` — live chapter/aggregate/command counts from Hecks's own Bluebook definitions
- `HecksUL.describe` — prints a human-readable summary of the entire language
- `ChapterSpecGenerator` — generates exhaustive RSpec specs from chapter IR (chapter + paragraph level)
- Generated specs cover every aggregate and command across all 15 chapters — the language spec IS the test suite

## Persistence
- Memory adapter for fast, zero-setup in-process storage
- PStore adapter — file-based object store using Ruby stdlib, zero dependencies, supports query with conditions/ordering/pagination
- SQL adapter via Sequel ORM supporting MySQL, PostgreSQL, and SQLite
- Repository pattern: `find`, `all`, `count`, `save`, `delete` on aggregates
- Instance-level `save`, `destroy`, `update` methods
- Collection proxies for `list_of` attributes with `create`, `delete`, `each`, `count`
- Automatic reference resolution with lazy loading from repository
- Optional event sourcing with `EventRecorder` and `Aggregate.history(id)` replay

## Querying
- `where(field: value)` filtering on aggregates
- `find_by(field: value)` for single-record lookup
- `order(:field)` and `order(field: :desc)` sorting
- OR conditions: `Pizza.where(style: "Classic").or(Pizza.where(style: "Tropical"))`
- `exists?` check without loading all records
- `pluck(:name)` for attribute-only results
- Aggregations: `sum(:price)`, `min(:price)`, `max(:price)`, `average(:price)`
- Batch operations: `delete_all`, `update_all(status: "archived")`
- Query operators: `gt`, `gte`, `lt`, `lte`, `not_eq`, `one_of`
- Named scopes callable as class methods
- Ad-hoc query support via `include_ad_hoc_queries` config

## Command & Event System
- Command bus with middleware pipeline
- Class-level command methods: `Pizza.create(name: "M")`
- Instance-level command methods: `cat.meow` auto-fills from instance attributes
- `Hecks::Command` mixin orchestrates full lifecycle (guard → handler → call → persist → emit → record)
- `Hecks::Query` mixin — queries are self-contained like commands
- Re-entrant policy protection (skips policies already in-flight)
- In-process event bus with subscriptions and wildcard `on_any`
- Cross-aggregate event subscribers
- Async subscriber and policy dispatch via configurable `async { }` block

## Smalltalk-Inspired REPL

### Sketch & Play
- Interactive session for incremental domain building (`Hecks.session`)
- `sketch!` / `play!` toggling — switch between modeling and execution modes
- `reload!` — re-read the domain DSL and reboot the playground without leaving play mode; clears events and data
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
- Command attribute chaining: `Post.create.title String` adds attribute to command
- Lifecycle from handle: `Post.lifecycle :status, default: "draft"`
- Transitions from handle: `Post.transition "PublishPost" => "published"`
- Value objects via PascalCase + block: `Post.Address { attribute :street, String }`
- Commands via snake_case + block: `Post.bake { attribute :temp, Integer }`
- Reference attributes: `Post.order_id reference_to("Order")`
- Terse single-line feedback after every operation (e.g. "title attribute added to Post")

### Console Tour
- Guided walkthrough via `hecks tour` — 15-step tour of sketch, play, and build
- Also available inside the console: `tour`
- CI-friendly: skips Enter pauses when stdin is not a TTY

### Architecture Tour
- Contributor walkthrough via `hecks tour --architecture` — 10-step tour of framework internals
- Covers monorepo layout, Bluebook DSL, Hecksagon IR, compiler pipeline, generators, workshop, AI tools, CLI registration, and spec conventions
- Each step displays relevant file paths for exploration

### Web Console
- Browser-based REPL via `hecks web_console [NAME]` — terminal-like interface at localhost:4567
- Safe command parser: no eval, only whitelisted Grammar commands execute
- Console endpoint disabled by default — requires `--enable-console` flag to activate
- Multi-domain support: load multiple domain files into a single web console with domain grouping
- Three-panel layout: domain tree sidebar, terminal center, event log sidebar
- Interactive domain diagram with aggregate nodes, reference arrows, and policy flow visualization
- Same implicit syntax as IRB — commands parsed as a safe command language
- Paren-style command syntax: `create_pizza(name: "Margherita")` alongside space-delimited
- Side panels auto-refresh after each command
- Command history with Up/Down arrows
- Web Components (Shadow DOM) for diagram rendering with custom events

### Session Features
- All session methods hoisted to top level in console
- AggregateHandle short method names: `attr`, `command`, `validation`, etc.
- Duplicate attribute detection
- `handle.build(**attrs)` — compile domain and return a live domain object
- Auto-normalize names to PascalCase
- `serve!` — start web explorer from REPL in background thread
- `promote("Comments")` — extract aggregate into its own standalone domain file
- `extend :logging` — apply extensions to live runtime without rebooting
- Play mode compiles domain on the fly with full Runtime
- Real-time event display and policy triggering feedback
- Event history with timestamps, reset/replay capability
- Suppressed backtraces by default — `backtrace!` / `quiet!` to toggle
- Persistent command history across sessions (`~/.hecks_history`)
- Session image save/restore: `save_image` / `restore_image` to snapshot and restore workshop state
- Named image labels: `save_image("checkpoint")` for multiple save points
- Image files stored in `.hecks/images/` with human-readable `.heckimage` format
- `list_images` to see all saved session snapshots
- `Hecks::TestHelper` for spec setup and constant cleanup

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
- Command names must be verb phrases (WordNet + custom verbs)
- Reactive policy events and triggers must reference existing elements
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
- `--strict` promotes warnings to errors; pre-commit hook blocks on errors

### IO Validator (`hecks-life check-io`)
- Asserts the bluebook is pure-memory by default — no IO leaks above the hecksagon adapter layer
- **Static IR scan**: flags IO-suggestive command names (`Deploy`, `Send`, `Push`, `Publish`, `Fetch`, `Sync`), past-tense external event names (`Deployed`, `Sent`), and pure-side-effect commands (emits but no state change, not Create or lifecycle)
- **Runtime smoke**: boots `Runtime::boot(domain)` (pure-memory, no `data_dir`, no hecksagon) and dispatches every dispatchable command — anything that panics or attempts IO is a hard error
- `hecks-life check-all` runs lifecycle + IO together

### Behavioral Tests (`hecks-life conceive-behaviors` + `behaviors`)
- New first-class DSL: `Hecks.behaviors "Pizzas" do ... end` — sibling to `Hecks.bluebook`, separate IR, separate parser, separate parity contract
- Test surface: `tests`, `setup`, `input`, `expect` — no IDs in the test bluebook (runner translates references↔ids internally)
- `conceive-behaviors` auto-generates `_behavioral_tests.bluebook` from any source bluebook by walking IR (every command, query, lifecycle transition, given clause)
- `behaviors` runner uses `Runtime::boot(domain)` — pure-memory, no hecksagon, no adapters
- Cascade-aware test generation: detects policy chains (emit→trigger), asserts on cascaded final state, skips redundant mid-chain tests
- Skips tests for non-equality givens that the chain planner can't auto-satisfy
- Conceiver parity test (`tests/conceiver_parity_test.rs`) keeps the bluebook conceiver and behaviors conceiver from drifting (shared `Conceiver` trait + shared `conceiver_common.rs` infrastructure)
- **VCR-style cascade lockdown** — for every command whose emit fires a policy chain, the conceiver emits a `kind: :cascade` test asserting the exact ordered list of events the runtime will publish (`expect emits: [E1, E2, ...]`). Drift in the policy graph (added or removed policy, retargeted trigger) breaks the test immediately.
- **Static cascade walker** (`hecks_life/src/cascade.rs`) — extracts the predicted event list from emit→policy→trigger graph; mirrors runtime `PolicyEngine` cycle detection (a policy is blocked while on the recursion stack, allowing diamond fan-in)
- **Cross-aggregate cascade setups** — generator walks `aggregates_touched_by_cascade` and emits a `Create` setup for every aggregate the cascade hops through, so triggered cross-aggregate commands find their target records
- **Two dispatch modes in the runner** — `dispatch` cascades policies (used by `kind: :cascade` tests), `dispatch_isolated` skips policy drain (used by setups so they don't overshoot the precondition state being tested)
- **`as:` reference alias kwarg** — canonical: `reference_to(Order, as: :recent_purchase)`. Five forms accepted: bare, `as:`, `role:` (legacy), `.as(:foo)` suffix, trailing-symbol shorthand
- **Clock anti-pattern check** — `lifecycle_validator` flags `:now` and `seconds_since(:field)` in mutations and givens. Time is infrastructure; the caller (test, hecksagon adapter, app) provides timestamps as command attributes.
- **Compound boolean givens** — interpreter supports `||` and `&&` (top-level split, `&&` binds tighter), plus `==`, `!=`, `>=`, `<=`, `>`, `<`, `field.any?`, `field.empty?`
- **List literal mutations** — `then_set :items, to: []` resolves to `Value::List(vec![])` (not `Str("[]")`); `then_set :items, to: [a, b]` resolves each element through the same value resolver

## Domain Interface Versioning
- `hecks version_tag <version>` — snapshot current domain DSL to `db/hecks_versions/<version>.rb` with metadata header
- `hecks version_log` — list all tagged versions newest-first with date and one-line change summary
- `hecks diff --v1 <v1> --v2 <v2>` — diff two tagged version snapshots with breaking change classification
- `hecks diff --v1 <v1>` — diff a tagged version against the working domain file
- `hecks diff` — diff working domain against latest tagged version (falls back to build snapshot)
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
- README generator with `{{tags}}` for auto-generated sections
- `{{connections}}` tag generates extension gem listing
- `{{smalltalk}}` tag generates Smalltalk features section from `SmalltalkFeatures` metadata

## AST-Based Domain Extraction (HEC-476)
- `Hecks::AstExtractor.extract(source)` — parse Bluebook DSL source into a plain hash IR using `RubyVM::AbstractSyntaxTree`, no eval
- `Hecks::AstExtractor.extract_file(path)` — read and parse a Bluebook file from disk
- Extracts: domain name, aggregates, attributes (with types, list, defaults), commands, references, value objects, entities, validations, specifications, queries, invariants, scopes, domain-level policies (with attribute maps), services, world goals, actors, sagas, modules, workflows, views
- Supports implicit PascalCase aggregate syntax (e.g. `Pizza do ... end` instead of `aggregate "Pizza" do ... end`)
- Safe for static analysis, linting, and tooling — never executes domain code

## Gem Architecture
- Core `hecks` gem has zero runtime dependencies
- Each extension is a top-level gem candidate at `lib/`
- `require "hecks"` gives you the core; each extension is a separate require
- Flattened namespace: `Hecks::Runtime`, not `Hecks::Services::Runtime`
- Hexagonal / ports-and-adapters: domain layer has zero persistence knowledge
- Domain gems are the bounded context boundaries

### Module Infrastructure (hecks_modules)
- `Hecks::ModuleDSL` — declarative `lazy_registry` for defining lazily-initialized registries
- All registries (targets, adapters, extensions, domains, dump formats, validations) use `lazy_registry`
- Zero module-level instance variable assignments — all state lazy-initialized on first access
- `Hecks::CoreExtensions` — namespace for Ruby core class extensions

### Deprecation System (hecks_deprecations)
- `HecksDeprecations.register(target_class, method_name) { ... }` — register deprecated shims
- Modules prepend warning wrappers onto target classes with `[DEPRECATION]` messages
- Covers hash-style `[]`, `to_h`, `== Hash` on refactored value objects
- Generated examples exclude this module — always use current API
- `HecksDeprecations.registered` — introspect all registered deprecations

### Rails Import (Reverse Engineering)
- `hecks import rails /path/to/app` — extract domain from existing Rails app
- `hecks import schema /path/to/schema.rb` — schema-only import
- `hecks extract /path/to/project` — auto-detect project type and extract domain
- Model-only extraction: works without schema.rb using belongs_to/has_many/validations/enums/AASM
- `Hecks::Import.from_directory(path)` — programmatic auto-detecting extraction
- `Hecks::Import.from_models(models_dir)` — programmatic model-only extraction
- Parses db/schema.rb: tables → aggregates, columns → typed attributes, foreign keys → references
- Parses app/models: validates → validations, enum → enum constraints, AASM → lifecycles
- Auto-generates Create commands for each aggregate
- Skips Rails internal tables (schema_migrations, active_storage_*, etc.)
- Preview mode with `--preview` flag

## Autophagy: Self-Hosting Compiler (Hecks v0)
- `hecks compile` — compile the entire Hecks framework into a single self-contained Ruby script
- `hecks compile --plan` — show compilation plan (file count and list) without writing
- `hecks compile --output NAME` — specify output file name (default: `hecks_v0`)
- `hecks compile --trace` — emit auditable trace of every compiler decision to stderr
- **Prism AST analysis** — uses Ruby's built-in Prism parser for dependency resolution
- **Bluebook IR consultation** — resolves method-call dependencies via chapter definitions
- **Two-layer dependency graph**: Layer 1 = Prism (constant refs, inheritance, mixins), Layer 2 = Bluebook (method-call edges)
- **Source files are require-free** — all internal requires stripped, Bluebook defines load order
- **SourceTransformer** — strips requires and expands compact class syntax at compile time
- **ConstantResolver** — namespace-aware constant resolution across all source files
- **CycleSorter** — greedy topo sort within dependency cycles, respecting wiring file order
- The compiled binary bundles all source files in load order with zero internal requires
- Injects forward declarations for load-order dependencies
- Pre-registers all bundled files in `$LOADED_FEATURES` to prevent double-loading
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
- Generators replace only the orchestration loops — same behavior, no runtime IR traversal
- Called explicitly via `RuntimeGenerator.new(domain, domain_module:).generate`

## CLI Commands
- `hecks new NAME` — scaffold a complete project with interactive world goals onboarding: 3-step prompt (yes/skip/doesn't apply), maps each goal to a real extension (`privacy→:pii`, `transparency→:audit`, `consent/security→:auth`, `equity→:tenancy`, `sustainability→:rate_limit`), deduplicates extensions, generates both `world_concerns` and `extend` calls in the Bluebook; `--no-world-goals` skips prompt for CI
- `hecks build` — validate and generate versioned gem
- `hecks build --gem` — produce a publishable `.gem` artifact after building (runs `gem build` on generated output); supported for `ruby` and `static` targets
- `hecks serve [--rpc]` — start REST or JSON-RPC server
- `hecks serve --watch` — hot reload: polls domain source for changes and rebuilds routes without restart
- `hecks console [NAME]` — interactive REPL with domain loaded
- `hecks validate` — check domain against DDD rules
- `hecks mcp` — start MCP server
- `hecks inspect` — show full domain definition including business logic (attributes, lifecycle, commands, policies, invariants, etc.)
- `hecks tree` — print all CLI commands as a grouped tree; `--format json` for tooling
- `hecks glossary` — print domain glossary to stdout; `--export` writes `glossary.md`
- `hecks dump` — show glossary, visualizer, and DSL output
- `hecks migrations` — schema migration management
- `hecks interview` — conversational onboarding that walks through domain definition interactively (name, aggregates, attributes, commands) and writes a Bluebook file
- `hecks docs update` — sync doc headers and READMEs
- All commands accept `--domain` flag consistently
- `--format json` on `validate`, `inspect`, and `tree` commands for Studio/tooling consumption

## Rails Integration (ActiveHecks)
- `Hecks.configure` block for Rails initializers
- Auto-detects `*_domain` gems in the Gemfile — zero config needed
- Auto-registers domain gem constants in Rails app
- SQL adapter config with database/host/name options
- Multi-domain support within a single Rails app
- Rails generators registered dynamically via Railtie
- `to_param` patched on command results — URL helpers work naturally
- `rails generate active_hecks:init` — one command sets up everything:
  - Adds `hecks_on_rails` to Gemfile
  - Detects domain gems (local directories or installed gems)
  - Creates initializer and app/models/HECKS_README.md
  - Enables ActionCable, creates cable.yml, mounts at /cable
  - Pins Turbo via importmap, adds turbo_stream_from to layout
  - Wires test helpers into spec/test files
- `rails generate active_hecks:live` — standalone live event setup
- `rails generate active_hecks:migration` — SQL migrations from domain changes

## HecksLive — Real-Time Domain Events
- Zero-config real-time event streaming via ActionCable + Turbo Streams
- Every domain event auto-broadcasts to connected browsers
- Railtie wires `event_bus.on_any` → `Turbo::StreamsChannel.broadcast_prepend_to`
- Views just need `<%= turbo_stream_from "hecks_live_events" %>` and `<div id="event-feed">`
- No custom JavaScript — standard Rails Turbo Streams
- Works across page navigations with `data-turbo-permanent`
- Stdout fallback when ActionCable is not available (plain Ruby apps)
- Custom channels via `HecksLive::Channel` subclass with `subscribe_to`

## Module Structure (HEC-370)
- `bluebook/` — grammar, IR nodes (DomainModel), DSL builders, validators, compiler, generators, visualizer, event storm parser
- `hecksties/` — core kernel: registries, errors, autoloads, utilities, version
- `hecks_templating/` — naming helpers + data contracts (type, view, event, migration, UI label)
- `hecks_runtime/` — command bus, ports, middleware, extensions, boot
- `hecks_features/` — vertical slice extraction, leaky slice detection, slice diagrams
- Standalone: heksagons, hecks_workshop, hecks_cli, hecks_static, hecks_on_the_go, hecks_persist, hecks_watchers
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

### llms.txt Generation
- `hecks llms` generates AI-readable domain summary with aggregates, commands, types, policies, flows
- `hecks build` includes `llms.txt` in every generated domain gem for automatic agent discovery
- Covers attributes with types, commands with parameters, validation rules, invariants, reactive chains

### MCP Server
- MCP-compatible runtime boots domains from IR without gem building — no disk I/O, no tmpdir, no `Hecks.build`
- `Hecks.load(domain)` is the public API for booting a Runtime from an IR object in memory
- `execute_command` MCP tool auto-enters play mode if not already active — removes a round-trip
- `Workshop#execute` delegates to the playground and auto-enters play mode when needed
- `hecks mcp` exposes all domain commands, queries, and repository operations as typed MCP tools
- `describe_domain` tool returns the entire domain model as structured JSON in one call
- Tool descriptions include parameter constraints, example values, return shapes, and guard conditions
- Rich descriptions for command tools: required attributes, emitted event, guards that might reject
- Every MCP tool produces visible human-readable feedback in Claude Code conversations
- `add_lifecycle` and `add_transition` tools for state machine building via MCP
- `add_attribute` tool for adding individual attributes to existing aggregates
- All tool output uses `capture_output` to show the same terse feedback as the REPL

### Command Bus Port (HTTP Adapter Boundary)
- `Hecks::HTTP::CommandBusPort` — explicit port between HTTP routes and the domain
- Mutations route through the `CommandBus` middleware pipeline via `port.dispatch`
- Reads validate against a safety whitelist (blocks `eval`, `system`, `exec`, `send`, etc.)
- Port-level middleware fires before the command bus — `port.use(:name) { |cmd, attrs, next_fn| ... }`
- Port middleware can short-circuit requests without reaching the domain
- `DomainServer` and `RpcServer` both use the port for all dispatch

### Self-Discoverable HTTP API
- `GET /_openapi` returns the OpenAPI 3.0 spec as JSON
- `GET /_schema` returns JSON Schema definitions
- AI agents hitting the HTTP API can self-discover every endpoint and type

### Structured JSON Errors
- All error classes (`GuardRejected`, `ValidationError`, `PreconditionError`, etc.) have `as_json`/`to_json`
- Returns error type, command, aggregate, message, and fix suggestion as machine-readable JSON
- AI agents can act on failures programmatically without string parsing

### Claude Code Integration
- `hecks claude` starts background file watchers, then launches Claude Code with `--dangerously-skip-permissions`
- `hecks_watchers` component: FileSize, CrossRequire, SpecCoverage, DocReminder, PreCommit, Runner, LogReader, Logger
- Watchers poll every second: file-size (180-line warning), cross-component require_relative, autoload registration
- `PreCommit` runner consolidates all watchers into a single pre-commit hook call (CrossRequire blocks, rest advisory)
- `DocReminder` watcher checks staged files for missing FEATURES.md and CHANGELOG updates
- PostToolUse hook reads `tmp/watcher.log` after every Edit/Write/Bash so Claude sees watcher output inline
- Watcher processes are cleaned up automatically when Claude exits
- Bin scripts are thin wrappers that delegate to `HecksWatchers::*` classes

### Watcher Agent (hecks_watcher_agent)
- `hecks fix-watchers` reads watcher log and creates PRs to fix issues
- Post-commit hook auto-launches agent when watchers report issues
- Hybrid fix engine: pure Ruby for simple fixes, Claude Code for complex ones
- Pure Ruby fixes: autoload entries, skeleton spec files
- Claude Code fixes: file size extraction, doc updates (FEATURES.md, CHANGELOG)
- Cross-require violations skipped (needs architectural decision)
- Creates branch, commits fixes, opens PR via `gh`

### Gem Packaging
- `hecks gem build` builds all component gems and the meta-gem via GemBuilder
- `hecks gem install` builds, installs, and cleans up all component gems in dependency order
- Components without a gemspec are skipped with a warning
- Stops on first failure rather than continuing with a broken build

### Domain Flow Generation
- `domain.flows` generates plain-English descriptions of reactive chains: command → event → policy → command
- `domain.flows_mermaid` generates Mermaid sequence diagrams of the same flows
- Cycle detection with `[CYCLIC]` markers
- Included in `domain.describe` output and `hecks dump`

### Domain Serialization
- `DomainSerializer.call(domain)` returns complete domain as structured Hash/JSON
- Aggregates with attributes (name, type, flags), commands, queries, specifications, policies, validations, invariants, value objects, entities
- Domain-level policies and services included

## Static Domain Generation (hecks_static)

### Zero-Dependency Output — Full DSL Parity
- `hecks build --static` generates a complete Ruby project with no hecks runtime dependency
- All DSL concepts generated: aggregates, value objects, entities, commands, events, ports, queries, validations, invariants, lifecycles, specifications, policies
- Generated project includes inlined runtime (Model, Command, EventBus, QueryBuilder, Specification)
- `bin/<domain> serve` starts an HTTP server with JSON API and HTML UI
- `bin/<domain> console` opens IRB with the domain loaded
- `bin/<domain> generate` regenerates domain code from `hecks_domain.rb`
- `bin/<domain> info` shows config, aggregates, ports, policies

### HTTP Server & UI
- WEBrick-based server with JSON API (one POST per command, GET per aggregate)
- Hot reload via `--watch` flag — polls domain source directory, reloads Bluebook and rebuilds routes on change (no restart needed, thread-safe via Mutex)
- HTML UI with index tables, show pages, create/update forms
- OpenAPI endpoint at `/_openapi`, validation rules at `/_validations`
- `GET /_events` — JSON event log (EventLogContract shape, same for Ruby and Go)
- `POST /_reset` — clear all data (button on config page, used by smoke tests)
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
- `check_port_access` runs in Command lifecycle before guards/preconditions
- UI buttons faded for unauthorized actions, forms blocked with error message
- JSON API returns 403 for unauthorized commands

### Validation (hecks_validations extension)
- Extracts validation rules from domain IR at build time
- `/_validations` JSON endpoint serves rules to clients
- Client-side JS validates before submit (presence, positive)
- Server-side validation check before dispatching to domain
- Domain-level `ValidationError` with `field:` and `rule:` for inline error display
- Three layers, one source: client → server → domain

### Persistence Adapters
- Memory adapter (default) — Hash-backed, zero config, always included
- Filesystem adapter — JSON files in `data/<aggregate>s/<uuid>.json`, survives restarts
- Switchable at runtime via Config page or `--adapter=` CLI flag

### Project Structure
- `hecks_domain.rb` — domain DSL (source of truth, regeneratable)
- `boot.rb` — wiring (stable, written once, not regenerated)
- `lib/` — domain code, runtime, server, adapters (regeneratable)
- `bin/<domain>` — CLI entry point

## Extensions

### hecks_filesystem_store
- JSON file persistence extension for dynamic mode
- `gem "hecks_filesystem_store"` auto-wires at boot
- `Hecks.boot(__dir__, adapter: :filesystem)` explicit wiring
- Same interface as memory: find, save, delete, all, count, query, clear

### hecks_validations
- Server-side parameter validation from domain rules
- Reads validation rules and VO invariants from domain IR at boot
- Provides `validate_params` method and `validation_rules` on domain module
- Wires into command bus as middleware

## Go Domain Generation (hecks_go)

### Go Output from Same DSL
- `Hecks.build_go(domain)` generates a complete Go project from the same domain IR
- Aggregate structs with `Validate()` method from DSL validations
- Value object structs with constructor invariant checks (`NewTopping()`)
- Command structs with `Execute(repo)` returning `(*Aggregate, *Event, error)`
- Event structs with `EventName()` and `GetOccurredAt()`
- Repository interfaces (Go's native port enforcement — compile-time, not runtime)
- Memory adapters with `sync.RWMutex` + `map`
- HTTP server using `net/http` (JSON API with POST per command, GET per aggregate)
- HTML UI with template-rendered pages: home, index tables, show detail, create/update forms, config page
- Go `html/template` views generated from ERB at build time — ERB is single source of truth
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
- Go aggregate `Validate()` enforces enum constraints from AggregateContract
- Go commands set lifecycle default status on create, enforce from-constraints and set target on update
- Go runtime package: EventBus (goroutine-safe pub/sub with history) and CommandBus (middleware pipeline)
- Go runtime interpreter: `Application` struct boots the domain, wires repos/buses, dispatches commands via `Run(name, json)`, returns `CommandResult` with aggregate + event
- Events published on every command execution, event count live on config page
- `go.mod` with only `google/uuid` dependency
- Go module registry: domain packages self-register via `init()` for runtime discovery
  - `runtime/registry.go` — thread-safe `Register(ModuleInfo)` and `Modules()` map
  - `register.go` per domain package — `init()` with aggregate/command lists
  - Multi-domain support: each subdomain package gets its own `init()` registration
- Type mapping: String→string, Integer→int64, Float→float64, list_of→[]Type

### Multi-Domain Go Target (HEC-237)
- `Hecks.build_go_multi(domains)` generates a multi-domain Go project
- Each bounded context gets its own Go package (e.g., `pizzas/`, `orders/`)
- Shared runtime package (EventBus, CommandBus) across all domains
- Combined server routing all domain aggregates under `/<domain>/<aggregate>` prefix
- Memory adapters nested under each domain package (`pizzas/adapters/memory/`)
- Single `go.mod` and `cmd/main/main.go` entry point
- `ProjectGenerator` supports `subdomain_mode` for reuse in multi-domain builds

## Node.js/TypeScript Target (`hecks build --target node`)

### Generated TypeScript Project
- TypeScript interfaces for each aggregate with typed fields (id, createdAt, updatedAt)
- Command functions returning typed event objects (create and update patterns)
- In-memory repository classes using `Map<string, T>` with all(), find(), save(), delete()
- Express REST server with GET list, GET by id, and POST command routes per aggregate
- `package.json` with express, typescript, ts-node, @types/express
- `tsconfig.json` with ESNext module, strict mode, ES2022 target
- README with getting started instructions

### Type Mapping (via TypeContract registry)
- String -> string, Integer -> number, Float -> number, Boolean -> boolean
- Date/DateTime -> string, JSON -> Record<string, unknown>
- list_of(X) -> X[], reference_to(X) -> string (ID)

### CLI Integration
- `hecks build --target node` registered in target registry
- Output: `<domain>_static_node/` directory with complete TypeScript project

## Web Explorer Extension (hecks_web_explorer)

### Domain UI as an Extension
- ERB templates for browsing aggregates, executing commands, viewing events
- Templates shared between Ruby static and Go targets
- Views: layout, home, index, show, form, config
- Renderer class with layout wrapping and HTML escaping
- Registers with runtime, auto-wires when loaded

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
- `ref("X")` alias for `reference_to("X")`
- `port :name, [methods]` compact inline form
- Command name inference: single verb + aggregate name, multi-word as-is
- Same IR output — implicit is sugar on top of explicit DSL
- Both forms can be mixed in the same file

## Testing

### Cross-Target Parity
- `hecksties/spec/cross_target_parity_spec.rb` — tagged `:parity`, excluded from default run
- Builds Pizzas domain into both Ruby static and Go targets from the domain IR
- Boots both HTTP servers, submits identical command sequences via browser-style form submission
- Fetches `/_events` from both, normalizes to event name lists, asserts equality
- Run explicitly: `bundle exec rspec hecksties/spec/cross_target_parity_spec.rb --tag parity`

### Rails Smoke Test
- `hecksties/spec/rails_smoke_spec.rb` — tagged `:slow`, excluded from default run
- Boots `examples/pizzas_rails` as a real subprocess against a free port
- Exercises full CRUD lifecycle: index, new, create, show, edit, update, destroy
- Validates 422 on invalid params via ActiveModel validations
- Run explicitly: `bundle exec rspec hecksties/spec/rails_smoke_spec.rb --tag slow`

## Event Sourcing (Phase 3)

### Optimistic Concurrency (HEC-65)
- Version stamping on aggregates via `Concurrency.stamp!(aggregate, version)`
- `ConcurrencyError` raised on version mismatch
- `VersionCheckStep` lifecycle step for commands with `expected_version`

### CQRS Read Model Store (HEC-63)
- `ReadModelStore` port with thread-safe get/put/delete/clear/keys
- Memory adapter for tests; swappable for Redis/SQL in production

### Event Versioning & Upcasting (HEC-70)
- `UpcasterRegistry` for registering schema migrations per event type
- `UpcasterEngine` chains upcasters from stored schema_version to latest
- Transparent upcasting on read — events stored at any version are automatically transformed

### Read Models / Projections (HEC-64)
- `EventStore` with append-only streams, auto-versioning, and global position ordering
- `ProjectionRebuilder` replays events through projection procs to rebuild read model state
- Supports rebuilding from all events or a single stream
- Integrates with `UpcasterEngine` for transparent upcasting during rebuild

### Outbox Pattern (HEC-80)
- `Outbox` port with store/pending/mark_published/published
- `OutboxStep` replaces `EmitStep` in the command lifecycle for transactional event capture
- `OutboxPoller` publishes pending events to the event bus (one-shot or background thread)
- Guarantees at-least-once event delivery

### Process Managers (HEC-67)
- `ProcessManager` event-driven state machine with correlation-based instance lookup
- Supports state transitions with `on(event_type, correlate:, transition:)` DSL
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
- **hecks-life serve generates full Tailwind web app** — `hecks-life serve path/to/hecks/ 3100` serves both JSON API and HTML UI from the same port
- Dark-themed Tailwind UI with sidebar navigation, dashboard metrics, domain detail pages with module cards, command forms, and fixture tables
- **Workflow pipeline UI** — aggregates with a `lifecycle` render as a horizontal step pipeline (default state highlighted in gold, arrows between steps, commands grouped under their target state)
- **Per-module fixture tables** — fixture records display inline inside each module card on the Build tab, filtered by aggregate name
- **Invariant gating on workflow steps** — commands with `givens` (preconditions) appear dimmed on their workflow step with the precondition expression shown in amber
- Command forms submit via fetch to the JSON dispatch endpoint — no page reload, inline success/error feedback
- Domain tags (`data-domain-aggregate`, `data-domain-command`) on all generated HTML elements
- **Contextual help icons** — every module card and command has a ? button that opens a help popup built from domain tags (aggregate name, description, field list, record/action counts)

## Examples
- Pizzas domain: plain Ruby app with commands, queries, collection proxies, event history
- Pizzas static Ruby: generated standalone Ruby project with HTTP server, UI, roles, filesystem persistence
- Pizzas static Go: generated Go project with HTTP server, memory adapters, same domain
- Rails pizza shop: full Turbo Streams app with admin, ordering, toppings, pricing, live events
- Banking domain: 4 aggregates, cross-aggregate policies, specifications, entities, SQLite
- Spaghetti Western: Rails-imported domain (gunslingers, duels, bounties, saloons) — demonstrates reverse-engineered DDD from ActiveRecord
- Governance: 5 bounded contexts (compliance, model registry, operations, identity, risk assessment) — 930 lines of DSL exercising every concept
