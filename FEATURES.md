# Hecks Framework — Feature List

## Domain Modeling DSL

### Core Structure
- Define domains with `Hecks.domain "Name" { }` block syntax
- Declare an explicit domain version with `Hecks.domain "Name", version: "2.1.0" { }` — semver and CalVer supported; propagates to generated gemspec and Go server header
- Define aggregates with attributes, commands, events, policies, queries, and scopes
- Inline aggregate definitions with `definition:` keyword — attaches a human-readable description to the aggregate IR, surfaced in `Hecks.aggregates` inspector output
- Define value objects as immutable nested types within aggregates
- Define entities within aggregates — sub-objects with identity (UUID), mutable, not frozen
- Multi-domain support with shared event bus across domains
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

### World Goals
- `world_goals :transparency, :consent, :privacy, :security` — opt-in ethical validation rules
- `:transparency` — commands must emit events (no silent mutations)
- `:consent` — user-like aggregate commands must declare actors
- `:privacy` — PII attributes must be `visible: false`; PII aggregate commands need actors
- `:security` — command actors must be declared at domain level
- **Mother Earth Report** — `hecks validate` shows a per-goal PASS/FAIL summary with violations listed

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
- `hecks_logging` — structured stdout logging with duration
- `hecks_rate_limit` — sliding window rate limiting per actor
- `hecks_idempotency` — command deduplication by fingerprint
- `hecks_transactions` — DB transaction wrapping when SQL adapter present
- `hecks_retry` — exponential backoff for transient errors

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

## Persistence
- Memory adapter for fast, zero-setup in-process storage
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

## CLI Commands
- `hecks new NAME` — scaffold a complete project with interactive world goals onboarding (opt-out by pressing Enter; skipped in non-interactive/CI)
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
- Core, ActiveModel, real-time, and persistence ship as separate packages
- `hecks_on_rails` bundles everything for Rails apps
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

## Examples
- Pizzas domain: plain Ruby app with commands, queries, collection proxies, event history
- Pizzas static Ruby: generated standalone Ruby project with HTTP server, UI, roles, filesystem persistence
- Pizzas static Go: generated Go project with HTTP server, memory adapters, same domain
- Rails pizza shop: full Turbo Streams app with admin, ordering, toppings, pricing, live events
- Banking domain: 4 aggregates, cross-aggregate policies, specifications, entities, SQLite
- Spaghetti Western: Rails-imported domain (gunslingers, duels, bounties, saloons) — demonstrates reverse-engineered DDD from ActiveRecord
- Governance: 5 bounded contexts (compliance, model registry, operations, identity, risk assessment) — 930 lines of DSL exercising every concept
