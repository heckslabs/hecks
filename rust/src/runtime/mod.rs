//! Hecks Runtime — executes domains from IR
//!
//! Dispatches commands, enforces givens, applies mutations,
//! emits events, triggers policies, updates projections.
//! The beating heart.
//!
//! Usage:
//!   let domain = parser::parse(&source);
//!   let mut rt = Runtime::boot(domain);
//!   let result = rt.dispatch("CreatePizza", attrs! { "name" => "Margherita" });
//!
//! [antibody-exempt: rust/src/runtime/mod.rs — kernel-floor runtime.
//!  i156 added the AmbiguousCommand variant for strict bare-name
//!  dispatch ; the rest is pre-i156. i221-B adds sweep-loop expansion
//!  in `drain_policies` + an `iter_data` parameter on
//!  `evaluate_value_spec` so `for_each:` dispatches resolve `from_iter
//!  (:field)` against per-record state — kernel-surface because the
//!  PM cascade lives here, no bluebook can describe its own driver.
//!  i220-1 fires the `:llm` adapter hook after each cascade dispatch
//!  inside `drain_policies` so PM/policy-driven cascade dispatches
//!  reach the named-adapter pipeline the same way top-level dispatch
//!  does — kernel-surface plumbing on the rem_branch.sh retirement
//!  arc, no bluebook can describe its own driver.]

mod aggregate_state;
pub(crate) mod command_dispatch;
mod event_bus;
pub mod loop_driver;
pub mod pm_engine;
pub(crate) mod interpreter;
pub mod adapter_io;
pub mod adapter_llm;
pub mod adapter_registry;
pub mod hexagon_resolution;
// adapter_terminal — host-only stdin/stdout REPL shim (drives
// `crate::run_stdin_loop`, which is gated out of wasm). The Worker
// has no terminal.
#[cfg(not(target_arch = "wasm32"))]
pub mod adapter_terminal;
pub mod shell_dispatcher;
mod middleware;
mod policy_engine;
mod projection;
mod repository;
// i728 runtime-as-bluebook strangler file-split — the persistence-resolution
// `impl Runtime` methods (dump_backend_map, unwired_aggregates) live in this
// GENERATED, golden-gated child module, not in mod.rs. Inherent impl in a
// child module attaches to Runtime ; regenerate with `storehouse specialize
// persistence_resolution`.
mod persistence_resolution;
// i728 file-split cluster 4 — the event/outbox driving methods
// (enqueue_and_drain, fire_driving_cron_ticks) generated into this child module.
mod event_driving;
// i750 out-of-process-adapter pump — `.world`→handler-child-env folding,
// relocated from `run_host::config` so the OutboundEvent drain
// (`reaction::pump_outbound_events`) resolves a handler's env without the
// soon-to-retire standalone host. `run_host::config` re-exports `map_config`.
pub mod adapter_env;
// i728 file-split cluster 4b — Phase-3 reaction delivery (react, react_ports,
// pump) generated into this child module.
mod reaction;
// i728 file-split cluster 7 — context-qualified read side (all_qualified,
// resolve_query_qualified) generated into this child module.
mod query;
// SQLite persistence backend — the SQL mirror of the heki Repository,
// activated by `adapter :sqlite, db:` in a hecksagon. Typed columns
// from the bluebook IR, one table per aggregate. LazyRepository
// multiplexes heki vs sqlite behind one forwarding surface.
// `sqlite_mapping` holds the IR→SQL type map + Value↔cell translation
// (extracted to keep each file single-concern + under the LoC cap).
// sqlite_mapping / sqlite_repository — host-only (they import
// `rusqlite`, which compiles C SQLite and has no wasm32 target).
// Gated out of the Cloudflare Worker build alongside the rusqlite
// dep in Cargo.toml ; the Worker uses the in-memory Repository.
#[cfg(not(target_arch = "wasm32"))]
pub mod sqlite_mapping;
#[cfg(not(target_arch = "wasm32"))]
pub mod sqlite_repository;
// wasm32 : a never-constructed stub so `lazy_repository`'s
// heki/sqlite multiplexer compiles unchanged. The Worker only ever
// builds the heki/memory backend (is_sql() is const-false on wasm),
// so every method here is `unreachable!`. Keeps the substrate switch
// in one place rather than cfg-splitting every forwarding method.
#[cfg(target_arch = "wasm32")]
pub mod sqlite_repository {
    //! wasm32 stub — see the comment at the cfg gate in runtime/mod.rs.
    use super::{AggregateState, Value};
    use crate::heki;
    use std::collections::HashMap;

    pub struct SqliteRepository;

    #[allow(unused_variables, clippy::new_ret_no_self)]
    impl SqliteRepository {
        pub fn new(
            aggregate_type: &str,
            db_path: &str,
            identified_by: Option<String>,
            columns: Vec<(String, String)>,
        ) -> Self {
            unreachable!("SqliteRepository is host-only — wasm uses the heki/memory backend")
        }
        pub fn id_for_command(&mut self, attrs: &HashMap<String, Value>) -> String { unreachable!() }
        pub fn save(&mut self, state: AggregateState, ctx: heki::WriteContext<'_>) { unreachable!() }
        pub fn delete(&mut self, id: &str, ctx: heki::WriteContext<'_>) { unreachable!() }
        pub fn find(&self, id: &str) -> Option<&AggregateState> { unreachable!() }
        pub fn find_mut(&mut self, id: &str) -> Option<&mut AggregateState> { unreachable!() }
        pub fn all(&self) -> Vec<&AggregateState> { unreachable!() }
        pub fn count(&self) -> usize { unreachable!() }
        pub fn seed_record(&mut self, state: AggregateState) { unreachable!() }
        pub fn next_id_value(&self) -> u64 { unreachable!() }
        pub fn set_next_id(&mut self, value: u64) { unreachable!() }
        pub fn query(
            &self,
            wheres: &[crate::ir::WhereClause],
            attrs: &HashMap<String, String>,
        ) -> Vec<AggregateState> { unreachable!() }
        pub fn ensure_indexes(&self, columns: &[String]) { unreachable!() }
    }
}
// i-lazy — boot-map lazy hydration. Wraps Repository in a OnceCell so
// boot constructs all 458 repos WITHOUT touching disk ; each repo's
// load_persisted runs on first access. Kills the ~4.2s eager-hydration
// tax on a single-shot dispatch (which touches exactly one repo).
mod lazy_repository;
pub mod seed_loader;
pub mod llm_dispatcher;
pub mod llm_providers;
pub mod prompt_scaffolder;
// i220 sub-gap 5 (compute-adapter-primitive) — sibling of llm_dispatcher
// for local computation. Adapters declared as `:compute` in a hecksagon
// route through `compute_dispatcher::call` which resolves
// `function_name` against the static `compute_functions` registry.
pub mod compute_dispatcher;
pub mod claude_tool_dispatcher;
// i593 — :mcp adapter family kernel hook. One behavior :
// invoke_mcp_tool (open stdio MCP session, call named tool with
// args, route response back into the cascade). Sibling to
// claude_tool_dispatcher ; registered into i557's framework
// registry alongside it. Shell hooks reach this via the new
// `storehouse mcp` subcommand family in main.rs.
pub mod mcp_dispatcher;
pub mod sms_dispatcher;
// i569 — :web_tool adapter family kernel hook. Two behaviors :
// perform_web_fetch (curl HTTP GET, URL-safety gated) and
// perform_web_search (DuckDuckGo HTML-lite). Sibling to
// claude_tool_dispatcher ; registered into i557's framework registry
// once that lands. This module exposes `lookup_hook` +
// `WEB_TOOL_BEHAVIOR_NAMES` for the registry to consume — `Runtime::
// dispatch` is deliberately NOT modified to call into it.
pub mod web_tool_dispatcher;
// i629 — the kernel-floor exec leaf. One behavior : perform_exec
// (run a local program, capture stdout/exit). The bespoke
// `resolve_exec_adapters` arm that used to drive it is RETIRED
// (adapters-as-bluebook, plan: structured-pondering-pie) ; this leaf
// is now reached only through `resolve_primitive_spawn` (the generic
// `Primitive::Process.Spawn` hook). Every former `:exec` binding —
// Inbox.Check, ProcessMacrophage.Sweep/Heal, the fibroblast sweep —
// is now an ordinary aggregate-qualified bluebook policy firing
// `Primitive::Process.Spawn`. The spawn syscall is the only imperative
// remainder ; the adapter PROTOCOL is plain bluebook policy/cascade.
pub mod exec_dispatcher;
pub mod driven_adapter_resolver;
// Sprint 14 actor-model quartet — per-aggregate-instance mailboxes,
// async event delivery, per-actor failure isolation, causal ordering.
// The mailbox layer wraps (not replaces) the existing synchronous
// dispatch path : command dispatch still returns synchronously (sync
// feel), event-driven cascades route through the registry. See
// `actor/mod.rs` for the architectural shape ; the 4 smoke tests in
// `actor::tests` flip each story's DiD gate.
//
// Host-only : the tokio substrate (sprint-14 tokio-mailbox-substrate)
// is cfg-gated on non-wasm32. tokio has no wasm32-unknown-unknown
// target ; the Cloudflare-worker build never reaches the actor
// dispatch path so the gate is structurally safe.
#[cfg(not(target_arch = "wasm32"))]
pub mod actor;
// Sprint 14 — sibling of driven_adapter_resolver. Fires `driving on`
// adapter handlers triggered by EXTERNAL signals (cron tick first ;
// http_post / file_watch parse but are runtime stubs pending listener
// wiring). See module-level doc for v1 scope.
pub mod driving_adapter_resolver;
// The pure tick-counter core of `storehouse drive` (the single-owner
// interval scheduler that fires `driving on interval` handlers live).
pub mod drive_scheduler;
// The append-only one-line-per-event shard backing the out-of-process
// Event Log (shards-plus-merge topology). Format + writer + offset reader.
pub mod event_shard;
pub mod projection_fold;
pub mod event_log;
// Phase 2 of the where() overhaul — filtered streaming scan of the Event
// Log : hydrate only matching lines (O(matches)) instead of the whole Log.
pub mod event_log_query;
// Phase 3 of the where() overhaul — the offset index for the Event Log, so
// Replay SEEKS to an aggregate's events instead of streaming. Safe by
// construction (commit-marker + full-scan fallback ; no false negatives).
pub mod event_log_index;
// Phase 1 of the where() overhaul — injection-safe SQL WHERE pushdown
// builder + executor. Host-only (rusqlite) ; the wasm build uses the
// heki/memory backend and never reaches it.
#[cfg(not(target_arch = "wasm32"))]
pub mod sql_query;
// The where()-pushdown READ surface on the SQL backend — query() + the
// Phase-3 expression indexes — split from sqlite_repository (CRUD substrate)
// by concern. Host-only (rusqlite).
#[cfg(not(target_arch = "wasm32"))]
pub mod sqlite_query;
// The SQL-pushdown ↔ where_matches parity oracle : asserts the
// connection-executed prefilter never diverges from the in-memory
// canonical matcher (contract-not-regex ; the two paths can't silently
// drift). Host-only — exercises a real SqliteRepository.
#[cfg(all(test, not(target_arch = "wasm32")))]
mod sql_query_tests;
#[cfg(all(test, not(target_arch = "wasm32")))]
mod query_parity_tests;
// Phase 4 of the where() overhaul — the CausationTrace lineage traversal
// (resolve_query_qualified's recursive branch), tested over a seeded chain.
#[cfg(all(test, not(target_arch = "wasm32")))]
mod causation_trace_tests;
// The merge half : tail N single-writer shards into the global ordered Log.
pub mod event_merge;
pub mod compute_functions;
// i557 — Phase-2 framework runtime. Walks
// `hecks_conception/aggregates/framework/{adapter_families,behavior_kinds}/`
// at boot and builds a typed registry of adapter families + behavior
// kinds + native kernel hooks. Part 1 lands the registry surface +
// boot wiring + kernel-hook seed for `invoke_claude_tool` ; part 2
// retires the hardcoded `:claude_tool` shortcut in `Runtime::dispatch`.
pub mod framework_registry;
// sprint-14 (storehouse-primitive-conception) — runtime index of the
// imperative kernel-floor leaves. Mirrors the Storehouse::Primitive
// bluebook records ; seeded at boot with the current hand-coded
// primitives (Process.Spawn / ClaudeTool.Invoke / WebTool.* / Compute /
// Llm / Shell / Sms). The runtime consults it BEFORE running its
// hard-coded match arms so a macrophage check can confirm every
// imperative leaf has a matching declaration.
pub mod primitive_registry;
// i622 — StoreHouse stdout logger. One-line records on stdout per
// dispatch, event, cascade, policy. Level gated by STOREHOUSE_LOG
// (quiet/normal/verbose). All four surfaces and the MCP child stderr
// route through this module so stdout is the single audit stream.
pub mod storehouse_log;
pub mod dispatch_detail;

pub use aggregate_state::AggregateState;
pub use command_dispatch::CommandResult;
pub(crate) use command_dispatch::apply_lifecycle_default;
pub use event_bus::{Event, EventBus};
pub use middleware::{CommandContext, MiddlewareStack, Phase};
pub use policy_engine::{PolicyEngine, PolicyTrigger};
pub use pm_engine::{PMBinding, PMEngine, PMInstanceState, PMTrigger};
pub use projection::Projection;
pub use repository::Repository;
pub use lazy_repository::{BackendKind, LazyRepository};

/// One row of the backend-map projection (i728) — which backend each repository
/// resolved to, without hydrating it. `Runtime::dump_backend_map` builds the Vec ;
/// the Phase-A enforcement gate diffs it before/after a change and treats any
/// unexpected backend flip as an automatic stop.
#[derive(Debug, Clone)]
pub struct BackendInfo {
    pub repo_key: String,
    pub kind: BackendKind,
    pub heki_path: Option<String>,
}

use crate::ir::Domain;
use crate::hecksagon_ir::Hecksagon;
use std::collections::HashMap;

/// Phase 3 — one enqueued reaction: a command result whose cross-
/// aggregate reactions have not yet been delivered. Held in the Runtime
/// outbox until `pump()` runs `react` for it.
#[derive(Debug, Clone)]
pub struct PendingReaction {
    pub result: CommandResult,
    pub command_name: String,
    pub attrs: HashMap<String, Value>,
}

pub struct Runtime {
    pub domain: Domain,
    pub repositories: HashMap<String, LazyRepository>,
    /// i735 defect 2 — aggregates whose wired `:sqlite` adapter FAILED to
    /// build at boot (SQL-incompatible column, unopenable db). Keyed by
    /// repo_key → the loud reason. Their repository is removed (no silent
    /// heki fallback) ; a dispatch against them returns
    /// `RuntimeError::PersistenceRefused` rather than panicking.
    pub refused_persistence: HashMap<String, String>,
    pub event_bus: EventBus,
    /// Phase 3 — the outbox. Enqueued reactions awaiting delivery by
    /// `pump()`. A command's core mutation pushes its result here and
    /// returns; the cross-aggregate reactions run later, each its own
    /// phase. Empty between pumps.
    pub outbox: std::collections::VecDeque<PendingReaction>,
    pub policy_engine: PolicyEngine,
    pub pm_engine: PMEngine,
    pub projections: Vec<Projection>,
    pub middleware: MiddlewareStack,
    pub data_dir: Option<String>,
    /// i221 — every hecksagon loaded alongside the domain. The
    /// `drain_policies` hook scans these for `:llm` adapters whose
    /// `response_into_target` matches a recently-dispatched command,
    /// substitutes the prompt template, calls the resolved provider,
    /// and dispatches the response back into the named target. Empty
    /// when the runtime is booted via the legacy `Runtime::boot(domain)`
    /// (no hecksagons known) — preserves backward compat with every
    /// existing caller that didn't carry hecksagons.
    pub hecksagons: Vec<Hecksagon>,
    /// i221 — provider registry keyed by backend name (`"test"`,
    /// `"claude"`, `"ollama"`). When empty (default), only the `:test`
    /// backend is implicitly available — claude/ollama require an
    /// explicit `register_llm_provider` call so unit tests can never
    /// silently shell out to a real model.
    pub llm_providers: HashMap<String, Box<dyn llm_providers::LlmProvider>>,
    /// i557 part 1 — Phase-2 framework registry. Populated at boot by
    /// `boot_with_framework_dir` (walks
    /// `<framework_dir>/adapter_families/*.hecksagon` +
    /// `<framework_dir>/behavior_kinds/*.hecksagon`) and seeded with
    /// the kernel hooks the runtime knows natively (today : just
    /// `invoke_claude_tool`). Default-constructed (empty + seeded
    /// hooks) when the runtime boots without a framework path —
    /// preserves backward compat with every caller that doesn't
    /// supply one. Read only by part 2 ; `Runtime::dispatch` still
    /// uses the hardcoded `:claude_tool` path in part 1.
    pub framework_registry: framework_registry::FrameworkRegistry,
    /// sprint-14 (storehouse-primitive-conception) — runtime index of
    /// the imperative kernel-floor leaves. Mirrors `Storehouse::Primitive`
    /// records ; populated by `seed_builtins` at boot so every runtime
    /// (test or production) starts with the current hand-coded
    /// primitives registered. The runtime consults it BEFORE running its
    /// hard-coded `resolve_primitive_*` arm — the lookup gives the
    /// macrophage a single source of truth and lays the substrate for
    /// future bluebook-overlay (Conceive adds entries on next boot).
    pub primitive_registry: primitive_registry::PrimitiveRegistry,
    /// i610 — MCP servers declared across the project's `*.world` files,
    /// unioned at boot by `attach_world_servers`. `resolve_mcp_adapters`
    /// looks a binding's `server` up here to read its `token_env`; the
    /// auth token itself is read from that env var at dispatch. Empty when
    /// the runtime boots without a world walk (tests / library callers) —
    /// the `:storehouse` spawn server stays resolvable regardless.
    pub world_servers: Vec<crate::world::ir::McpServer>,
    /// i610 — absolute path of the `*.world` file the gmail (or other)
    /// server was resolved from, for the resolve-log line. None until a
    /// world walk attaches servers.
    pub world_servers_path: Option<String>,
    /// Sprint 14 world-wires-real-adapters — adapter bindings declared
    /// in `*.world` files, unioned at boot by
    /// `attach_world_adapter_bindings`. The driven_adapter_resolver
    /// looks each handler's adapter name up here to decide canned
    /// (no entry) vs real (entry's values stand in for the wrapped-call
    /// return). Empty when the runtime boots without a world walk —
    /// every adapter falls back to canned (memory-by-default).
    pub world_adapter_bindings: Vec<crate::world::ir::AdapterBinding>,
    /// Per-adapter `.world` CONFIGS — the pizzas-exemplar
    /// `Domain::Agg.verb("Adapter") do … end` form, keyed by the lowercased
    /// adapter name (config_for). The host folds these into a handler's env.
    /// Distinct from world_adapter_bindings (the older `adapter "Name" do …`
    /// driven-adapter form).
    pub world_configs: Vec<crate::world::ir::ExtensionConfig>,
    /// Sprint 14 (retire-sync-cascade-pipeline) — monotonic counter of
    /// events that traversed `enqueue_and_drain`. The dispatch-time
    /// Sync/Actor fork retired with the sync-cascade pipeline ; every
    /// dispatch now publishes inline through the event bus. The
    /// mailbox-registry wiring tests in `migration_coexistence_test.rs`
    /// drive `enqueue_and_drain` directly to pin the per-mailbox FIFO +
    /// cross-aggregate parallelism preconditions that the actor-per-
    /// aggregate-instance + async-event-delivery-bus stories will lift
    /// back into dispatch later. The mailbox routes through
    /// `mailbox_registry` (`wire-mailbox-registry-into-event-bus`) so
    /// per-aggregate causal ordering + per-actor failure isolation are
    /// real properties of the runtime, not just a counter.
    pub mailbox_drained: usize,
    /// Sprint 14 (`wire-mailbox-registry-into-event-bus`) — the actor
    /// model's per-`(aggregate_type, aggregate_id)` mailbox set.
    /// `Runtime::enqueue_and_drain` enqueues into the addressed mailbox
    /// (lazy-created on first delivery) and then synchronously drains
    /// it through the existing `event_bus.publish` pipeline. The drain
    /// step is what makes the publish ACTUALLY route through the actor
    /// model : sync command dispatch is preserved (the drain happens on
    /// the calling thread before `dispatch` returns), but causal
    /// ordering is now mailbox-FIFO + idempotency dedup runs at the
    /// mailbox boundary instead of being absent. Cross-aggregate
    /// parallelism (event on A while slow handler runs on B → A not
    /// blocked) is proven by `Mailboxes::drain_all_in_parallel`
    /// in the actor unit tests ; the bus-level entry point keeps the
    /// sync-feel contract so callers don't fork.
    pub mailbox_registry: actor::Mailboxes,
    /// i750 out-of-process-adapter pump — the conception / aggregates ROOT the
    /// runtime was booted against (the `<root>` a re-entering handler shells
    /// `storehouse <root> ...` against). Set by the CLI dispatch path
    /// (`dispatch_hecksagon`) after boot ; `pump_outbound_events` passes it to
    /// each detach-spawned handler as `HECKS_ROOT`. None for library/test
    /// callers that boot without a root — those leave OutboundEvents pending
    /// (no handler to spawn into a root-less runtime).
    pub aggregates_root: Option<String>,
    /// Phase-4 causation — the last Log event_id recorded for each domain
    /// aggregate, keyed `"<type>::<id>"`. `record_event_append` updates it after
    /// it appends ; `cause_for_cascade` reads it so a cascaded command's events
    /// can stamp `causation_id` = the triggering event, making CausationTrace
    /// bite on live data. In-process, per-realm, transient (rebuilt as events
    /// record) — it carries no persistence and is empty for root dispatches.
    pub last_event_id_by_agg: HashMap<String, String>,
}

impl Runtime {
    pub fn boot(domain: Domain) -> Self {
        Self::boot_with_data_dir(domain, None)
    }

    /// i221 — boot with hecksagons attached so the LLM dispatcher's
    /// `drain_policies` hook can resolve `:llm` adapters whose
    /// `response_into_target` references a freshly-dispatched command.
    pub fn boot_with_hecksagons(
        domain: Domain,
        data_dir: Option<String>,
        hecksagons: Vec<Hecksagon>,
    ) -> Self {
        // Framework substrate — an effect binding needs the OutboundEvent
        // event-out port to record deliveries. Merge the embedded framework
        // outbox aggregate so ANY root (a self-contained example included) can
        // round-trip an effect port without copying the bluebook. Gated on an
        // effect binding being present ; a domain already declaring
        // OutboundEvent wins (no double-load).
        let domain = Self::ensure_outbox_substrate(domain, &hecksagons);
        let mut rt = Self::boot_with_data_dir(domain, data_dir);
        rt.hecksagons = hecksagons;
        // Persistence override (i642) — when a hecksagon declares
        // `adapter :sqlite, db: "..."`, rebuild every repository on the
        // SQL backend pointed at that db. Default (memory/heki) leaves
        // the heki-backed repos built by boot_with_data_dir untouched.
        // Runs AFTER hecksagons attach because boot_with_data_dir has no
        // hecksagon in scope to read the override from.
        // sqlite override is host-only ; on wasm32 the Worker always
        // runs the in-memory repository (the rusqlite dep is gated out).
        #[cfg(not(target_arch = "wasm32"))]
        rt.apply_sqlite_persistence();
        // i728 keystone — make `adapter :memory` actually select Backend::Memory.
        // Until this ran, :memory was inert : a declared-:memory aggregate fell
        // through to the implicit heki default, indistinguishable from unwired.
        // Ungated — memory is host- AND wasm-valid, so it runs on every target.
        rt.apply_memory_persistence();
        // bucket-3 step 4 — the hexagon-binding CONSULT. Reads the NEW
        // port-verb binding surface (`Pizzas::Order.persisted_by("Heki")`)
        // that steps 1-3 parse + resolve, and rebuilds each
        // persistence-family-bound aggregate on the backend its adapter
        // names. Runs LAST so a binding (the new surface) wins over a legacy
        // persistence block ; additive for every aggregate with no binding.
        rt.apply_hexagon_persistence();
        rt
    }

    /// The embedded framework outbox bluebook — the OutboundEvent event-out
    /// port, compiled in as runtime standard-library substrate so any booted
    /// domain with an effect binding gets it without copying. Single source
    /// of truth : the conception's canonical framework bluebook.
    const OUTBOX_SUBSTRATE: &'static str = include_str!(
        "../../../hecks_conception/aggregates/framework/hexagon/outbound_event.bluebook"
    );

    /// Merge the framework outbox aggregate into `domain` when (a) some
    /// attached hecksagon declares an EFFECT binding (a bind carrying `on:` —
    /// a verdict `charged_by(... ) do success/failure end` OR a fire-and-forget
    /// `voiced_by(..., on:)` with no verdict) and (b) the domain doesn't already
    /// declare OutboundEvent. The outbox is needed exactly when an effect port
    /// exists ; an effect-free domain stays untouched, and a domain that already
    /// carries OutboundEvent (the conception, or an example that copied it) wins
    /// — no double-load. Discriminator is `on` (the triggering event), NOT a
    /// verdict : persistence binds carry no `on`, fire-and-forget binds do.
    fn ensure_outbox_substrate(mut domain: Domain, hecksagons: &[Hecksagon]) -> Domain {
        let has_effect = hecksagons
            .iter()
            .any(|h| h.bindings.iter().any(|b| !b.on.is_empty()));
        if !has_effect || domain.aggregates.iter().any(|a| a.name == "OutboundEvent") {
            return domain;
        }
        let substrate = crate::parser::parse(Self::OUTBOX_SUBSTRATE);
        for agg in substrate.aggregates {
            if !domain
                .aggregates
                .iter()
                .any(|e| e.name == agg.name && e.context == agg.context)
            {
                domain.aggregates.push(agg);
            }
        }
        domain
    }

    /// Test-harness boot (i735 plan step 4) : every aggregate gets the
    /// EXPLICIT in-process `Backend::Memory` repository, not the implicit
    /// `Backend::Heki { data_dir: None }` default. "The harness chooses its
    /// storage" — in-process, no disk, alive for the process and gone on
    /// restart. The behaviors runner boots through this so the corpus stays
    /// explicitly wired once the unwired-=-error enforcement flip lands.
    pub fn boot_in_memory(domain: Domain) -> Self {
        let mut rt = Self::boot(domain);
        rt.force_memory_repositories();
        rt
    }

    /// `boot_in_memory` + attached hecksagons, so the behaviors runner's
    /// `driven on` adapter handlers still fire while every repository is
    /// memory-backed.
    pub fn boot_in_memory_with_hecksagons(domain: Domain, hecksagons: Vec<Hecksagon>) -> Self {
        let mut rt = Self::boot_with_hecksagons(domain, None, hecksagons);
        rt.force_memory_repositories();
        rt
    }

    /// TRANSITIONAL — first-class factories phase 1 ; phase 2 deletes
    /// this with the two-path dispatch split. Each Factory gains a
    /// Command VIEW in the runtime's command table so the existing
    /// index-based Resolution / cmd_for machinery dispatches factory
    /// verbs unchanged. is_create truth comes from the factories vec
    /// (see command_dispatch phase_03_prepare), never from the view.
    fn materialize_factory_commands(mut domain: Domain) -> Domain {
        for agg in &mut domain.aggregates {
            for f in agg.factories.clone() {
                if agg.commands.iter().any(|c| c.name == f.name) { continue; }
                agg.commands.push(crate::ir::Command {
                    name: f.name,
                    description: f.description,
                    role: f.role,
                    attributes: f.attributes,
                    references: f.references,
                    emits: f.emits,
                    emits_identified_by: f.emits_identified_by,
                    givens: f.givens,
                    mutations: f.mutations,
                });
            }
        }
        domain
    }

    /// i221 — register an LLM provider under a backend name. Lets the
    /// caller wire `:claude` / `:ollama` (or test doubles) without
    /// touching the dispatcher. Idempotent on the key.
    pub fn register_llm_provider(
        &mut self,
        backend: impl Into<String>,
        provider: Box<dyn llm_providers::LlmProvider>,
    ) {
        self.llm_providers.insert(backend.into(), provider);
    }

    pub fn boot_with_data_dir(domain: Domain, data_dir: Option<String>) -> Self {
        // TRANSITIONAL — first-class factories phase 1 (phase 2 DELETES
        // this). Factories become dispatchable by materializing a Command
        // view into the RUNTIME's in-memory command table only ; the
        // parsed IR (dumps, parity, validators) keeps factories separate.
        // The two-path dispatch split (Factory → mint / Command → load)
        // replaces this seam wholesale.
        let domain = Self::materialize_factory_commands(domain);
        let mut repositories = HashMap::new();
        for agg in &domain.aggregates {
            // i142 Tier 2 — key repositories by (context, name) so
            // same-name aggregates in different contexts get distinct
            // Repository instances (and distinct heki paths).
            let key = repo_key(agg.context.as_deref(), &agg.name);
            repositories.insert(
                key,
                // i-lazy — construct lazily : no disk read here. The
                // repo hydrates (via Repository::new_with_context) on
                // first find/all/save/etc. Single-shot dispatches touch
                // one repo ; daemons warm each on first touch.
                LazyRepository::new(
                    &agg.name,
                    data_dir.clone(),
                    agg.identified_by.clone(),
                    agg.context.clone(),
                ),
            );
        }

        let mut policy_engine = PolicyEngine::new();
        for policy in &domain.policies {
            policy_engine.register(
                &policy.name,
                &policy.on_event,
                &policy.trigger_command,
                policy.with.clone(),
            );
        }

        let mut pm_engine = PMEngine::new();
        for pm in &domain.process_managers {
            pm_engine.register(pm);
        }
        // Phase D — load persisted PM instances from heki so transitions
        // resume across storehouse subprocess forks (production daemons
        // fork per dispatch ; without this, in-memory state evaporates
        // and PMs effectively don't accumulate).
        pm_engine.load_persisted(data_dir.as_deref());

        let projections = domain
            .aggregates
            .iter()
            .map(|agg| projection::auto_projection(&agg.name))
            .collect();

        Runtime {
            domain,
            repositories,
            refused_persistence: HashMap::new(),
            event_bus: EventBus::new(),
            outbox: std::collections::VecDeque::new(),
            policy_engine,
            pm_engine,
            projections,
            middleware: MiddlewareStack::new(),
            data_dir,
            hecksagons: Vec::new(),
            llm_providers: HashMap::new(),
            // i557 part 1 — boot without a framework dir leaves the
            // family + behavior maps empty but still seeds the native
            // kernel hooks. Discovery-aware callers use
            // `boot_with_framework_dir` (or set the field directly).
            framework_registry: framework_registry::FrameworkRegistry::build_from_dir(
                std::path::Path::new("/nonexistent")
            ),
            primitive_registry: {
                // sprint-14 — seed every runtime with the current
                // kernel-floor primitives. Boot-without-framework still
                // gets the imperative-leaf index because the seed list
                // is structural to the runtime (the dispatchers ship in
                // the binary), not contingent on a framework conception
                // path. Future overlay from the Storehouse::Primitive
                // .heki store can layer on top here.
                let mut reg = primitive_registry::PrimitiveRegistry::new();
                reg.seed_builtins();
                reg
            },
            world_servers: Vec::new(),
            world_servers_path: None,
            world_adapter_bindings: Vec::new(),
            world_configs: Vec::new(),
            mailbox_drained: 0,
            mailbox_registry: actor::Mailboxes::new(),
            aggregates_root: None,
            last_event_id_by_agg: HashMap::new(),
        }
    }

    /// i557 part 1 — boot with hecksagons AND a framework directory so
    /// the registry can discover adapter families + behavior kinds at
    /// boot. The framework dir is typically
    /// `<aggregates_dir>/framework` (e.g.
    /// `hecks_conception/aggregates/framework`). Falls back to the
    /// kernel-hook-only registry if the dir doesn't exist — safe for
    /// callers that don't ship a framework conception.
    ///
    /// `Runtime::dispatch` itself doesn't consult the registry yet
    /// (part 2 retires the hardcoded `:claude_tool` path) ; this
    /// constructor just lands the substrate.
    pub fn boot_with_framework_dir(
        domain: Domain,
        data_dir: Option<String>,
        hecksagons: Vec<Hecksagon>,
        framework_dir: &std::path::Path,
    ) -> Self {
        let mut rt = Self::boot_with_data_dir(domain, data_dir);
        rt.hecksagons = hecksagons;
        rt.framework_registry =
            framework_registry::FrameworkRegistry::build_from_dir(framework_dir);
        rt
    }

    pub fn dispatch(
        &mut self,
        command_name: &str,
        attrs: HashMap<String, Value>,
    ) -> Result<CommandResult, RuntimeError> {
        // Structural cutover : `dispatch` IS the async outbox path. The core
        // mutation touches ONE aggregate ; cross-aggregate reactions go to the
        // outbox and are delivered by the pump as SEPARATE transactions, then
        // the cycle guard resets. It settles in-process (pump before return) so
        // callers still see a settled cascade — but no reaction ever runs
        // inline with the command. Roots without the CascadeRun outbox fall
        // back to the in-memory pump (== the prior synchronous react), so
        // behaviour is preserved there. Synchronous-between-aggregates is now
        // structurally unrepresentable : there is no inline-reaction path left.
        let r = self.dispatch_impl(command_name, attrs)?;
        self.pump_outbox();
        self.pump();
        self.policy_engine.reset_in_flight();
        Ok(r)
    }

    /// Phase 3 — enqueue a command's reactions WITHOUT running the pump.
    /// The core mutation touches ONE aggregate and returns; the cross-
    /// aggregate reactions sit in the outbox until `pump()` delivers each
    /// as its own phase. Proves the async seam: a sibling aggregate is
    /// unchanged after this returns and only changes once `pump()` runs.
    pub fn dispatch_deferred(
        &mut self,
        command_name: &str,
        attrs: HashMap<String, Value>,
    ) -> Result<CommandResult, RuntimeError> {
        self.dispatch_impl(command_name, attrs)
    }

    fn dispatch_impl(
        &mut self,
        command_name: &str,
        attrs: HashMap<String, Value>,
    ) -> Result<CommandResult, RuntimeError> {
        // i622 — dispatch entry log. One stdout line per top-level
        // dispatch, gated by STOREHOUSE_LOG. The invocation id is the
        // dispatch's `id` attr when present (matches i613's envelope),
        // falling back to a short hex token derived from the system
        // clock so every dispatch carries SOMETHING addressable.
        let invocation_id = attrs.get("id")
            .map(|v| v.to_string())
            .unwrap_or_else(|| {
                // wasm-safe clock : raw std::time::SystemTime::now()
                // panics "time not implemented" on wasm32 (CF Worker).
                // Route through clock::now_duration (i630).
                let d = crate::clock::now_duration();
                format!("inv_{:x}", d.subsec_nanos() as u64 ^ d.as_secs())
            });

        // i697 — open the rich dispatch-detail scope BEFORE the terse
        // dispatch_entry below, so the dispatch line itself is the first
        // entry in the rich block's event timeline. The scope's Drop
        // emits the full pretty-JSON block (covers the `?` error path
        // too). Cascades go through command_dispatch::dispatch_cascade,
        // not Runtime::dispatch, so exactly one scope is open per
        // top-level dispatch and the timeline forms one clean tree.
        let args_json = dispatch_detail_args_json(&attrs);
        let mut detail_scope =
            dispatch_detail::DispatchScope::begin(&invocation_id, command_name, args_json);

        storehouse_log::dispatch_entry(command_name, &invocation_id, None);

        // i622 verbose — per-attribute trace. One line per attr the
        // caller passed. Gated to the Verbose level inside the logger.
        for (k, v) in &attrs {
            storehouse_log::attribute_trace(
                command_name, &invocation_id, k, &v.to_string()
            );
        }

        // Middleware: before
        let ctx = CommandContext {
            command_name: command_name.to_string(),
            attrs: attrs.clone(),
            result: None,
        };
        self.middleware.run_before(&ctx);

        // Core dispatch. On error, feed the scope the error message so
        // its Drop emits a bright-red error block, THEN propagate.
        let result = match command_dispatch::dispatch(self, command_name, attrs) {
            Ok(r) => r,
            Err(e) => {
                detail_scope.finish("error", format!("{:?}", e)
                    .chars().map(|c| if c == '"' { '\'' } else { c }).collect::<String>()
                    .lines().next().map(|s| format!("\"{}\"", s)).unwrap_or_else(|| "\"error\"".into()));
                return Err(e);
            }
        };

        // i622 — event emission log. The dispatch produced an event ;
        // emit a one-liner naming the aggregate, event, and the
        // originating invocation id. Suppressed at quiet.
        if let Some(ref ev) = result.event {
            storehouse_log::event_emitted(
                &ev.aggregate_type, &ev.name, &ev.aggregate_id
            );
        }

        // Breadcrumb : write the entry-point command (the top-level
        // dispatch the user / CLI invoked) to a tiny plaintext file
        // under data_dir. The statusline reads it.
        //
        // Two filters keep the statusline glyph showing what's actually
        // INTERESTING, not the constant body-daemon traffic :
        //
        //   1. Top-level only — `drain_policies`'s cascade calls go
        //      through `command_dispatch::dispatch` directly and don't
        //      touch the breadcrumb. Without this, the cascade leaf
        //      (Synapse.DecaySynapse / Awareness.RecordMoment / Mode.
        //      SetAttentive) drowned the entry-point variety.
        //
        //   2. Non-daemon only — when HECKS_DAEMON=1 is set in the
        //      environment, the dispatch is body-cycle plumbing
        //      (mindstream.sh, pulse_organs.sh, heart/breath loops)
        //      and the breadcrumb is suppressed. The statusline glyph
        //      then only updates when a HUMAN-driven dispatch fires
        //      (Antibody.RegisterExemption from the prompt, Mood.
        //      Express, etc.) — exactly the "what are we working on"
        //      signal the bar is for.
        let is_daemon = std::env::var("HECKS_DAEMON").ok().as_deref() == Some("1");
        if !is_daemon {
            if let Some(ref dir) = self.data_dir {
                // wasm-safe clock (i630) — see invocation_id above.
                let now = crate::clock::now_duration().as_secs();
                let path = format!("{}/.last_dispatch", dir.trim_end_matches('/'));
                let phrase = self.format_breadcrumb_phrase(command_name, &result);
                let _ = std::fs::write(&path,
                    format!("{}\n{}\n", phrase, now));
            }
        }

        // Middleware: after
        let ctx = CommandContext {
            command_name: command_name.to_string(),
            attrs: ctx.attrs,
            result: Some(CommandResult {
                aggregate_id: result.aggregate_id.clone(),
                aggregate_type: result.aggregate_type.clone(),
                event: result.event.clone(),
                deltas: result.deltas.clone(),
            }),
        };
        self.middleware.run_after(&ctx);

        // Update projections
        if let Some(ref event) = result.event {
            for proj in &mut self.projections {
                proj.apply(event);
            }
        }

        // Phase 3 — outbox + pump. The core mutation above touched ONE
        // aggregate. Its cross-aggregate reactions (policy/PM cascade,
        // IO-edge adapters, hecksagon `driven on`) are enqueued and run by
        // `react` in a SEPARATE pump phase, never inline here. Eager callers
        // auto-pump so the cascade still settles before return;
        // `dispatch_deferred` skips the pump to prove the async seam.
        // Event-out messaging port — record a durable OutboundEvent for every
        // standalone (separate-program) adapter subscribing to this event via
        // an EFFECT binding, so an out-of-process host can consume it. Sync
        // domain bookkeeping on emit (the async charge happens off-core in the
        // host) ; no-op when OutboundEvent isn't loaded or nothing subscribes.
        self.record_effect_outbound(&result);
        // (Event-sourcing append moved into dispatch_inner — the universal
        // door — so cascade reactions, which bypass THIS wrapper via
        // dispatch_cascade, are recorded in the Log too. See command_dispatch.)
        // Transactional outbox — record this command's domain reactions to
        // the persistent CascadeRun outbox. The reaction is delivered ONLY by
        // pump_outbox (its own transaction, on a later tick), never inline.
        if self.record_cascade_run(&result) {
            // Deferred ASYNC path — domain reactions recorded to the persistent
            // outbox (delivered later by pump_outbox, each its own transaction).
            // The impure PORTS fire eagerly here so tools / AI still run in-band.
            self.react_ports(&result, command_name, &ctx.attrs);
        } else {
            // No persistent outbox (CascadeRun not loaded) or nothing to react
            // to — fall back to the in-memory deferred path: enqueue for pump(),
            // which runs the full react() later. Held until pump, never dropped.
            self.outbox.push_back(PendingReaction {
                result: result.clone(),
                command_name: command_name.to_string(),
                attrs: ctx.attrs.clone(),
            });
        }

        // i697 — feed the rich scope the final result state (the
        // aggregate's fields JSON after all adapters settle). The scope's
        // Drop then emits the full coloured block.
        let result_state_json = self
            .find(&result.aggregate_type, &result.aggregate_id)
            .map(dispatch_detail_state_json)
            .unwrap_or_else(|| "{}".to_string());
        detail_scope.finish("ok", result_state_json);

        Ok(result)
    }

    /// Event-sourcing Log writer (i-event-sourcing) — append one immutable
    /// `EventSourcing::Event` to the durable Log per delta this command
    /// produced. The out-of-domain sibling of `record_cascade_run` /
    /// `record_effect_outbound` : it records a framework aggregate from
    /// inside the dispatch path via `dispatch_cascade`. The `Event`
    /// aggregate is `identified_by :event_id`, so persisting it yields a
    /// durable, GLOBAL (not per-business-aggregate) append-only Log — the
    /// source of truth. v1 (coexist-then-migrate) : the eager heki current-
    /// state write stays as the Snapshot cache, so reads are unchanged.
    ///
    /// Sequence is the Log's own record count + 1. Append is the sole writer
    /// and never deletes, so count == max sequence, and the persisted Log
    /// self-seeds the sequence across restarts (count() hydrates from disk on
    /// first access) — no runtime counter to keep in sync.
    ///
    /// Recursion guard : skips the EventSourcing domain's own aggregates so
    /// Append never appends. (Belt-and-suspenders — `dispatch_cascade` does
    /// not re-enter this hook ; only the eager dispatch wrapper calls it.)
    fn record_event_append(&mut self, result: &CommandResult, command_name: &str, causation_id: &str) {
        // GATE (default OFF) — the in-process Log writer persists via DEFAULT
        // heki (whole-file read-modify-write), which CLOBBERS under concurrent
        // writers, so the live governance Log silently drops events. Per Chris
        // (2026-06-20) the Event Log moves OUT-OF-PROCESS (an async projection,
        // single-writer). Until that lands, event-sourcing is gated OFF so no
        // lossy Log runs. Set HECKS_EVENT_SOURCING=1 to re-enable once the
        // out-of-process writer owns event.heki. Sibling of HECKS_REPLY_OOP_LLM.
        if std::env::var("HECKS_EVENT_SOURCING").is_err() {
            return;
        }
        if result.deltas.is_empty() {
            return;
        }
        let event = match &result.event {
            Some(e) => e.clone(),
            None => return,
        };
        // No-op when the Event Log aggregate isn't loaded (e.g. a single-
        // bluebook example boot without the EventSourcing framework chapter).
        let es_key = repo_key(Some("EventSourcing"), "Event");
        if !self.repositories.contains_key(&es_key) {
            return;
        }
        // Infra guard — never event-source the runtime's own machinery.
        // These are MECHANISM, not domain intent : the runtime's delivery
        // bookkeeping (CascadeRun / OutboundEvent / Cascade carry cascades),
        // its process-spawn side-effects (Process), and its liveness
        // supervision (ProcessSentinel / ProcessMacrophage sweep + heal).
        // The bluebook makes them read models OF the Log, so sourcing them
        // would be circular noise — and their ids are process-ephemeral, so
        // fold(Log) can never reconstruct the live store (the verify-projection
        // drift that motivated this list, 2026-06-21).
        if projection_fold::is_infra_mechanism(event.aggregate_type.as_str()) {
            return;
        }
        // Recursion guard — never event-source the EventSourcing aggregates
        // themselves (Append must not append).
        if self.domain.aggregates.iter().any(|a| {
            a.name == event.aggregate_type
                && a.context.as_deref() == Some("EventSourcing")
        }) {
            return;
        }
        // The shard dir : a `shards/` sibling of the Event repo's heki store
            // dir, so the merge daemon's --global (event.heki) and the shards it
            // folds live under one event_sourcing/ root. Memory-backed Event
            // (no disk) has no shard target — skip.
            let store_dir = match self.repositories.get(&es_key).and_then(|r| r.heki_path()) {
                Some(d) => d,
                None => return,
            };
            let shard_dir = std::path::Path::new(&store_dir).join("shards");

            // command = verb + inputs (the caller's intent, recorded as fact ;
            // never re-executed by a fold). inputs = the emitted event data JSON.
            let verb = command_name.to_string();
            let inputs = {
                let mut obj = serde_json::Map::new();
                for (k, v) in &event.data {
                    obj.insert(k.clone(), value_to_json(v));
                }
                serde_json::Value::Object(obj).to_string()
            };
            // lineage : one correlation id per originating dispatch ; causation
            // is populated empty this phase (ids ENABLED, facet-queries DEFERRED).
            let correlation_id =
                format!("{}::{}::{}", event.aggregate_type, event.aggregate_id, event.name);
            let recorded_at = storehouse_log::now_iso8601();
            let agg_name = event.aggregate_type.clone();
            let agg_id = event.aggregate_id.clone();
            // One Event per delta, appended to THIS process's private shard.
            // shard + seq + event_id are assigned inside append_to_process_shard
            // (single-writer per process => lossless at any size, no clobber).
            // The merge daemon folds shards into the global event.heki and
            // assigns the authoritative global sequence ; we do NOT compute a
            // global sequence here (the old repo-count+1 is what clobbered).
            let mut last_event_id = String::new();
            for (field, value) in result.deltas.clone() {
                // Reserve this record's shard identity BEFORE dispatch : Event
                // is identified_by :event_id, so the command needs its
                // globally-unique id up front. event_id = "{shard}-{seq}" is
                // the merge's dedup key ; seq is the per-process sequence.
                let (shard, seq) = match event_shard::reserve(&shard_dir) {
                    Some(t) => t,
                    None => return,
                };
                let event_id = format!("{}-{}", shard, seq);
                let mut command_vo = HashMap::new();
                command_vo.insert("verb".to_string(), Value::Str(verb.clone()));
                command_vo.insert("inputs".to_string(), Value::Str(inputs.clone()));
                let mut delta_vo = HashMap::new();
                delta_vo.insert("field".to_string(), Value::Str(field.clone()));
                delta_vo.insert("value".to_string(), Value::Str(value.to_string()));
                let mut sequence_vo = HashMap::new();
                sequence_vo.insert("value".to_string(), Value::Int(seq as i64));
                let mut attrs = HashMap::new();
                last_event_id = event_id.clone();
                attrs.insert("event_id".to_string(), Value::Str(event_id));
                attrs.insert("aggregate_name".to_string(), Value::Str(agg_name.clone()));
                attrs.insert("aggregate_id".to_string(), Value::Str(agg_id.clone()));
                attrs.insert("command".to_string(), Value::Map(command_vo));
                attrs.insert("delta".to_string(), Value::Map(delta_vo));
                attrs.insert("causation_id".to_string(), Value::Str(causation_id.to_string()));
                attrs.insert("correlation_id".to_string(), Value::Str(correlation_id.clone()));
                attrs.insert("actor".to_string(), Value::Str("system".to_string()));
                attrs.insert("sequence".to_string(), Value::Map(sequence_vo));
                attrs.insert("recorded_at".to_string(), Value::Str(recorded_at.clone()));
                // Core dispatch (no pump) — EventSourcing::Event.Append's save
                // routes through the AppendLog adapter to THIS process's shard.
                // The recursion guard above skips the EventSourcing aggregates,
                // so this inner Append never re-enters this hook.
                let _ = command_dispatch::dispatch(self, "EventSourcing::Event.Append", attrs);
            }
            // Phase-4 causation : remember this command's last recorded event
            // so a cascade off this aggregate can stamp it as its cause.
            if !last_event_id.is_empty() {
                self.note_last_event(&agg_name, &agg_id, &last_event_id);
            }
        }

    /// Phase-4 causation — note the Log event_id just recorded for a domain
    /// aggregate, so a later cascade off it can stamp `causation_id`. Keyed
    /// "<type>::<id>" ; the latest write wins (a command's last delta-event is
    /// the representative cause). In-process, transient.
    fn note_last_event(&mut self, agg_type: &str, agg_id: &str, event_id: &str) {
        self.last_event_id_by_agg
            .insert(format!("{}::{}", agg_type, agg_id), event_id.to_string());
    }

    /// Phase-4 causation — the triggering event_id for a cascaded dispatch. A
    /// cascade carries its upstream (type, id) as a hint ; the cause is the
    /// last Log event recorded for that aggregate (the event whose processing
    /// fired this cascade). Empty for a root dispatch (no hint) or an upstream
    /// that recorded no events — both leave causation_id empty, where
    /// CausationTrace stops.
    pub(crate) fn cause_for_cascade(&self, hint: &Option<(String, String)>) -> String {
        hint.as_ref()
            .and_then(|(t, i)| self.last_event_id_by_agg.get(&format!("{}::{}", t, i)).cloned())
            .unwrap_or_default()
    }

    /// Event Log consolidation trigger — fires the merge fold IFF the
    /// dispatched command is the Consolidation maintenance command. Called from
    /// dispatch_inner (so BOTH the manual path AND the driver's dispatch_cascade
    /// reach it). A no-op for every other command. Replaces the run_merge
    /// daemon : `storehouse drive` fires Consolidation.Consolidate on an
    /// interval, and this runs one merge pass.
    fn run_consolidate_if(&self, command_name: &str) {
        if command_name == "EventSourcing::Consolidation.Consolidate" {
            self.run_consolidate();
        }
    }

    /// One merge pass : fold this realm's per-process Event shards into the
    /// global ordered Log, writing WHERE the Event repository reads (so a
    /// reader sees the consolidated log — the writer/reader never diverge).
    /// Kernel-floor persistence IO : the shard byte-IO + the fold live in
    /// event_shard / event_merge (siblings of heki.rs) ; this only wires the
    /// realm's paths to them. The checkpoint advances only after a durable
    /// global write, so a failed write retries next pass and a crash mid-pass
    /// replays idempotently (dedup by event_id). No-op when the Event repo is
    /// memory-backed (no shard dir).
        fn run_consolidate(&self) {
        let es_key = repo_key(Some("EventSourcing"), "Event");
        let store_dir = match self.repositories.get(&es_key).and_then(|r| r.heki_path()) {
            Some(d) => d,
            None => return,
        };
        let shard_dir = std::path::Path::new(&store_dir).join("shards");
        // The global Log path — the APPEND-ONLY JSONL file the AppendLog adapter
        // reads (event_log::global_path with the EventSourcing context), so the
        // merge writer and the aggregate reader never diverge. NOT a heki store :
        // heki is for snapshots, the LOG is append-only (event_log.rs).
        let global = event_log::global_path(&store_dir, Some("EventSourcing"));
        let checkpoint = shard_dir.join(".merge.checkpoint.json");
        let shards = match event_merge::discover_shards(&shard_dir) {
            Ok(s) => s,
            Err(_) => return,
        };
        let mut cp = event_merge::load_checkpoint(&checkpoint)
            .unwrap_or_else(|_| event_merge::Checkpoint::new());
        if let Ok(batch) = event_merge::merge_pass(&shards, &mut cp) {
            // Adopt the advanced checkpoint only after a durable global write
            // (empty batch = nothing to write, offsets unchanged — safe to save).
            let write_ok = batch.is_empty()
                || event_merge::write_batch_to_global(&global, &batch).is_ok();
            if write_ok {
                let _ = event_merge::save_checkpoint(&checkpoint, &cp);
                // Reclaim the per-process shards this merge has now FULLY
                // folded whose owning process is DEAD — the GC half of
                // consolidation (every dispatch process leaves an orphan
                // shard ; without this ~/.heki/.../shards grows without
                // bound). Only when the live-process set is TRUSTWORTHY :
                // live_pids() returns None on a failed/empty ps and we
                // reclaim nothing, never risking a live process's open
                // shard. Persist the pruned checkpoint when anything went.
                if let Some(live) = live_pids() {
                    let n = event_merge::reclaim_consumed_shards(
                        &shards,
                        &mut cp,
                        &|pid| live.contains(&pid),
                    );
                    if n > 0 {
                        let _ = event_merge::save_checkpoint(&checkpoint, &cp);
                    }
                }
            }
        }
    }

    /// One-time migration of the global Event Log from compressed whole-file
    /// heki (`event.heki`) to the append-only JSONL substrate (`event.log`).
    /// Reads the heki store, orders records by sequence, writes them as JSONL,
    /// seeds the `.seq` sidecar from the max sequence, and renames the old heki
    /// aside (`.premigration`, reversible). Returns (before, after) counts.
    /// Refuses if `event.log` already exists. Idempotent at the realm level :
    /// run once per realm, before the new append-only writer goes live.
    pub fn migrate_event_log_to_jsonl(&self) -> Result<(usize, usize), String> {
        let es_key = repo_key(Some("EventSourcing"), "Event");
        let store_dir = self
            .repositories
            .get(&es_key)
            .and_then(|r| r.heki_path())
            .ok_or("EventSourcing::Event not loaded (no store dir)")?;
        let old = crate::heki::path_for(&store_dir, "Event", Some("EventSourcing"));
        let new = event_log::global_path(&store_dir, Some("EventSourcing"));
        if std::path::Path::new(&new).exists() {
            return Err(format!("{} already exists — already migrated", new));
        }
        let store = crate::heki::read(&old).map_err(|e| format!("read {}: {}", old, e))?;
        let before = store.len();
        let seq_of = |r: &crate::heki::Record| -> i64 {
            r.get("sequence")
                .and_then(|v| v.as_object())
                .and_then(|m| m.get("value"))
                .and_then(|v| v.as_i64())
                .unwrap_or(0)
        };
        let mut records: Vec<&crate::heki::Record> = store.values().collect();
        records.sort_by_key(|r| seq_of(r));
        if let Some(parent) = std::path::Path::new(&new).parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let mut buf = String::new();
        let mut max_seq = 0i64;
        for r in &records {
            max_seq = max_seq.max(seq_of(r));
            // heki::Record is a HashMap ; serialize it as a JSON object line.
            let obj: serde_json::Map<String, serde_json::Value> =
                r.iter().map(|(k, v)| (k.clone(), v.clone())).collect();
            buf.push_str(&serde_json::Value::Object(obj).to_string());
            buf.push('\n');
        }
        std::fs::write(&new, &buf).map_err(|e| format!("write {}: {}", new, e))?;
        event_log::write_next_seq(&new, (max_seq + 1).max(1) as u64);
        // Reversible backup of the old heki store.
        let _ = std::fs::rename(&old, format!("{}.premigration", old));
        let after = event_log::load_states(&new).len();
        Ok((before, after))
    }

    /// The unconsolidated Log tail : the Event records that live in the shards
    /// but have NOT yet been folded into the global event.heki. The COMPLETE
    /// Log is the consolidated event.heki PLUS this tail — `verify-projection`
    /// needs both to reconstruct a LIVE aggregate, because a continuously-
    /// dispatching aggregate (e.g. the 2s InboxPoller) always has its freshest
    /// event sitting in a shard, ~consolidation-cadence ahead of event.heki.
    ///
    /// READ-ONLY : unlike run_consolidate, this neither writes the global Log
    /// nor saves the advanced checkpoint — it loads a private checkpoint copy,
    /// runs one merge_pass to collect the post-checkpoint records, and discards
    /// the mutated copy. So a verifier observes the tail without perturbing the
    /// live consolidate driver. The returned states carry the Event's fields in
    /// the same nested shape (delta{field,value}, sequence{value}, recorded_at)
    /// the consolidated reader produces, so the fold treats both uniformly.
    pub fn unconsolidated_log_tail(&self) -> Vec<AggregateState> {
        let es_key = repo_key(Some("EventSourcing"), "Event");
        let store_dir = match self.repositories.get(&es_key).and_then(|r| r.heki_path()) {
            Some(d) => d,
            None => return Vec::new(),
        };
        let shard_dir = std::path::Path::new(&store_dir).join("shards");
        let checkpoint = shard_dir.join(".merge.checkpoint.json");
        let shards = match event_merge::discover_shards(&shard_dir) {
            Ok(s) => s,
            Err(_) => return Vec::new(),
        };
        let mut cp = event_merge::load_checkpoint(&checkpoint)
            .unwrap_or_else(|_| event_merge::Checkpoint::new());
        let batch = match event_merge::merge_pass(&shards, &mut cp) {
            Ok(b) => b,
            Err(_) => return Vec::new(),
        };
        // Discard cp : read-only, no save_checkpoint / write_batch_to_global.
        batch
            .iter()
            .map(|rec| {
                let mut st = AggregateState::new("");
                for (k, v) in &rec.event {
                    st.set(k, json_to_value_recursive(v));
                }
                st
            })
            .collect()
    }

    /// Transactional outbox — when a dispatched command's event has domain
    /// reactions (policy triggers, driven-adapter dispatches, PM dispatches),
    /// write a persistent `CascadeRun.Begin` recording them as ordered Steps.
    /// The outbox IS the async delivery queue : pump_outbox drains each step
    /// as its own transaction on a later tick. No-op when the CascadeRun
    /// aggregate isn't loaded or the event has no reactions (the caller then
    /// falls back to the in-memory pump).
    fn record_cascade_run(&mut self, result: &CommandResult) -> bool {
        let event = match &result.event {
            Some(e) => e.clone(),
            None => return false,
        };
        if !self.domain.aggregates.iter().any(|a| a.name == "CascadeRun") {
            return false;
        }
        // Reactions = (command, payload_json). Each payload is resolved
        // EXACTLY as the eager path would, so the pump's later dispatch sees
        // the same attrs. Policy triggers: event data + `with` literals, then
        // inject_refs so the triggered command's reference_to resolves.
        let mut reactions: Vec<(String, String)> = Vec::new();
        // Policy triggers. Capture through policy_engine.react so the in_flight
        // reentrancy guard breaks cyclic cascades (a re-entrant policy within
        // this pump session is skipped) ; in_flight is not cleared here — the
        // fork-per-dispatch process boundary resets it.
        let policy_resolved: Vec<(String, HashMap<String, Value>)> = self
            .policy_engine
            .react(&event)
            .into_iter()
            .map(|t| {
                let mut data = t.event_data.clone();
                for (k, v) in &t.with_data {
                    data.insert(k.clone(), v.clone());
                }
                (t.command_name.clone(), data)
            })
            .collect();
        for (cmd, mut data) in policy_resolved {
            // inject_refs matches the BARE command name (DropPendingTaskCount),
            // not the FQN (Story.DropPendingTaskCount) the policy binding carries.
            // Strip the aggregate prefix so the reference_to target resolves into
            // the payload HERE — the pump dispatches with a CascadeRun upstream, so
            // the payload must already carry every ref (the eager path resolves it
            // from the real upstream inside dispatch_inner instead).
            let bare = cmd.rsplit('.').next().unwrap_or(&cmd).to_string();
            self.inject_refs(&bare, &event.aggregate_type, &event.aggregate_id, &mut data);
            let mut obj = serde_json::Map::new();
            for (k, v) in &data {
                obj.insert(k.clone(), value_to_json(v));
            }
            reactions.push((cmd, serde_json::Value::Object(obj).to_string()));
        }
        for (cmd, attr_map) in driven_adapter_resolver::enumerate_driven_dispatches(self, &event) {
            let mut obj = serde_json::Map::new();
            for (k, v) in &attr_map {
                obj.insert(k.clone(), value_to_json(v));
            }
            reactions.push((cmd, serde_json::Value::Object(obj).to_string()));
        }
        // PM-driven reactions. enumerate_pm_dispatches advances the PM state
        // machine ; each PM dispatch carries its own resolved attrs (for_each
        // sweep + with_spec + inject_refs).
        for (cmd, attr_map) in self.enumerate_pm_dispatches(&event) {
            let mut obj = serde_json::Map::new();
            for (k, v) in &attr_map {
                obj.insert(k.clone(), value_to_json(v));
            }
            reactions.push((cmd, serde_json::Value::Object(obj).to_string()));
        }
        if reactions.is_empty() {
            return false;
        }
        let steps: Vec<Value> = reactions
            .iter()
            .enumerate()
            .map(|(i, (cmd, payload))| {
                let mut m = HashMap::new();
                m.insert("ref".to_string(), Value::Str(format!("step-{}", i + 1)));
                m.insert("command".to_string(), Value::Str(cmd.clone()));
                m.insert("order".to_string(), Value::Int((i as i64) + 1));
                m.insert("status".to_string(), Value::Str("pending".to_string()));
                m.insert("attempt".to_string(), Value::Int(0));
                m.insert("last_error".to_string(), Value::Str(String::new()));
                m.insert("payload".to_string(), Value::Str(payload.clone()));
                Value::Map(m)
            })
            .collect();
        // run_id encodes the upstream so the pump can dispatch each step with
        // the ORIGINAL triggering aggregate as upstream (== the eager path),
        // letting reference_to(SameAggregate) resolve via dispatch_inner.
        let run_id = format!("{}::{}::{}", event.aggregate_type, event.aggregate_id, event.name);
        let mut retry = HashMap::new();
        retry.insert("max_attempts".to_string(), Value::Int(0));
        retry.insert("backoff".to_string(), Value::Str("none".to_string()));
        let mut attrs = HashMap::new();
        attrs.insert("run_id".to_string(), Value::Str(run_id));
        attrs.insert("trigger_event".to_string(), Value::Str(event.name.clone()));
        attrs.insert("steps".to_string(), Value::List(steps));
        attrs.insert("retry_policy".to_string(), Value::Map(retry));
        let agg_type = event.aggregate_type.clone();
        let agg_id = event.aggregate_id.clone();
        let _ = command_dispatch::dispatch_cascade(
            self,
            "CascadeRun::CascadeRun.Begin",
            attrs,
            &agg_type,
            &agg_id,
        );
        true
    }

    /// Event-out messaging port (effect-port slice a) — record one durable
    /// `OutboundEvent` per standalone adapter that subscribes to this
    /// command's emitted event via an EFFECT binding (`Agg.charged_by("X",
    /// on: E, into: "Agg.Ok | Agg.No")`). The out-of-process analog of
    /// `record_cascade_run` : where that records IN-PROCESS domain reactions
    /// for the pump, this records OUT-OF-PROCESS deliveries for a separate-
    /// program host to consume. Runs on emit ; sync domain bookkeeping (the
    /// host does the async charge off-core). No-op when `OutboundEvent` isn't
    /// loaded or no effect binding names this event. delivery_id =
    /// source::id::event::adapter, so a re-emit is the same idempotent delivery.
    fn record_effect_outbound(&mut self, result: &CommandResult) {
        let event = match &result.event {
            Some(e) => e.clone(),
            None => return,
        };
        if !self.domain.aggregates.iter().any(|a| a.name == "OutboundEvent") {
            return;
        }
        // adapter -> family, family -> verb : the typed attach checkpoint, so a
        // broken bind records nothing (mirrors resolve_bindings' flat-map).
        let mut adapter_family: HashMap<String, String> = HashMap::new();
        let mut family_verb: HashMap<String, String> = HashMap::new();
        for hex in &self.hecksagons {
            for a in &hex.adapters {
                adapter_family.insert(a.name.clone(), a.family.clone());
            }
            for f in &hex.families {
                family_verb.insert(f.name.clone(), f.verb.clone());
            }
        }
        // Snapshot the Record attr-maps under the immutable borrow ; dispatch
        // after (dispatch_cascade takes &mut self).
        let mut records: Vec<HashMap<String, Value>> = Vec::new();
        for hex in &self.hecksagons {
            for b in &hex.bindings {
                // Effect port subscribing to THIS event. A VERDICT bind
                // (charged_by) carries success/failure ; a FIRE-AND-FORGET bind
                // (voiced_by — speech is heard, not awaited) carries
                // neither. BOTH record an OutboundEvent and BOTH are consumed by
                // the host ; fire-and-forget simply dispatches no verdict on
                // delivery. Persistence binds (persisted_by) carry no `on`, so
                // they never match an event name here.
                if b.on != event.name {
                    continue;
                }
                match adapter_family.get(&b.adapter) {
                    Some(fam)
                        if family_verb.get(fam).map(String::as_str)
                            == Some(b.verb.as_str()) => {}
                    _ => continue,
                }
                // Verdict commands are `Aggregate.Command` ; prepend the bind's
                // context to form the dispatch FQN the host will re-enter with.
                let context = b.aggregate.rsplit_once("::").map(|(c, _)| c).unwrap_or("");
                let qualify = |cmd: &str| {
                    if context.is_empty() {
                        cmd.to_string()
                    } else {
                        format!("{}::{}", context, cmd)
                    }
                };
                // Guard BOTH verdicts : a fire-and-forget bind has empty
                // success/failure, and qualify("") would wrongly yield
                // "Context::". Empty stays empty so the host takes the
                // fire-and-forget path (dispatch no verdict).
                let success = if b.success.is_empty() { String::new() } else { qualify(&b.success) };
                let failure = if b.failure.is_empty() { String::new() } else { qualify(&b.failure) };
                let mut data_obj = serde_json::Map::new();
                for (k, v) in &event.data {
                    data_obj.insert(k.clone(), value_to_json(v));
                }
                let payload = serde_json::Value::Object(data_obj).to_string();
                let delivery_id = format!(
                    "{}::{}::{}::{}",
                    event.aggregate_type, event.aggregate_id, event.name, b.adapter
                );
                let mut attrs = HashMap::new();
                attrs.insert("delivery_id".to_string(), Value::Str(delivery_id));
                attrs.insert("adapter".to_string(), Value::Str(b.adapter.clone()));
                attrs.insert("event".to_string(), Value::Str(event.name.clone()));
                attrs.insert("source_type".to_string(), Value::Str(event.aggregate_type.clone()));
                attrs.insert("source_id".to_string(), Value::Str(event.aggregate_id.clone()));
                attrs.insert("payload".to_string(), Value::Str(payload));
                attrs.insert("success_command".to_string(), Value::Str(success));
                attrs.insert("failure_command".to_string(), Value::Str(failure));
                attrs.insert("attempts".to_string(), Value::Int(0));
                records.push(attrs);
            }
        }
        for attrs in records {
            let _ = command_dispatch::dispatch_cascade(
                self,
                "OutboundEvent::OutboundEvent.Record",
                attrs,
                &event.aggregate_type,
                &event.aggregate_id,
            );
        }
    }

    /// C3 (transactional outbox) — enumerate the PM-driven dispatches for an
    /// event, returning (command, attrs) WITHOUT dispatching. Capture-only
    /// twin of the PM block in `drain_policies`: it runs the PM state machine
    /// (react + persist + set), because PM dispatches can't be enumerated
    /// without advancing the machine — that state evolution belongs to the
    /// PM's own aggregate. It then resolves each dispatch's attrs (for_each
    /// sweep + with_spec + inject_refs) exactly as the eager path does, and
    /// hands the resolved dispatches back for the outbox to record as Steps.
    /// Called ONLY on the deferred path (not the eager body hot path), so a
    /// divergence from drain_policies can never touch the live body.
    fn enumerate_pm_dispatches(&mut self, event: &Event) -> Vec<(String, HashMap<String, Value>)> {
        let mut out: Vec<(String, HashMap<String, Value>)> = Vec::new();
        let pm_triggers = self.pm_engine.react(event);
        for t in pm_triggers.clone() {
            let _ = self.pm_engine.persist_instance(
                &t.pm_name,
                &t.correlation_id,
                self.data_dir.as_deref(),
            );
            let set_pairs = self.pm_set_pairs(&t, event);
            for (attr, value) in set_pairs {
                self.pm_engine
                    .apply_set(&t.pm_name, &t.correlation_id, &attr, value);
            }
            let _ = self.pm_engine.persist_instance(
                &t.pm_name,
                &t.correlation_id,
                self.data_dir.as_deref(),
            );
            for dispatched in &t.dispatches {
                let iter_records: Vec<HashMap<String, Value>> = match &dispatched.for_each {
                    Some(spec) => {
                        let mut q_attrs: HashMap<String, String> = HashMap::new();
                        for (k, vspec) in &spec.query_inputs {
                            if let Some(v) = self.evaluate_value_spec(
                                vspec, event, &t.pm_name, &t.correlation_id, None,
                            ) {
                                q_attrs.insert(k.clone(), v.to_string());
                            }
                        }
                        self.sweep_records(spec, &q_attrs)
                    }
                    None => vec![HashMap::new()],
                };
                let is_sweep = dispatched.for_each.is_some();
                for record in &iter_records {
                    let mut data: HashMap<String, Value> = HashMap::new();
                    let iter_arg = if is_sweep { Some(record) } else { None };
                    for (key, spec) in &dispatched.with_spec {
                        if let Some(v) = self.evaluate_value_spec(
                            spec,
                            event,
                            &t.pm_name,
                            &t.correlation_id,
                            iter_arg,
                        ) {
                            data.insert(key.clone(), v);
                        }
                    }
                    self.inject_refs(
                        &dispatched.command_name,
                        &event.aggregate_type,
                        &event.aggregate_id,
                        &mut data,
                    );
                    out.push((dispatched.command_name.clone(), data));
                }
            }
        }
        out
    }

    /// Render the statusline breadcrumb phrase for a just-resolved
    /// dispatch — the two-segment-plus-dot shape Chris locked
    /// 2026-05-12 :
    ///
    ///   `Domain::Aggregate.Command` (commands, PascalCase)
    ///   `Domain::Aggregate.query_name` (queries, snake_case)
    ///
    /// Where :
    ///
    ///   - **Domain** — the bounded context the aggregate was declared
    ///     in. Prefers `aggregate.context` (the bluebook namespace,
    ///     i.e. `Hecks.bluebook "Name"`), falls back to the merged
    ///     `Domain.category`, finally falls back to the aggregate name
    ///     so the slot never renders empty (matches Chris's
    ///     `Tools.Bash → Tools::Tools.Bash` example).
    ///   - **Aggregate** — the root aggregate name (always the heki
    ///     record being mutated ; entity-targeted dispatches still
    ///     render the aggregate, NOT the entity — the entity slot
    ///     was retired with the 2026-05-12 format correction).
    ///   - **Command** — the bare command name (last `.`-segment of
    ///     the dispatched address ; strips any `Context.` or
    ///     `Aggregate.` prefixes the caller passed).
    ///
    /// Two segments + dot. No entity slot in the path. The earlier
    /// three-segment form (`Tools::Tools::Tools.Bash`) was rejected
    /// for visible duplication ; the dispatcher already knows which
    /// aggregate the command belongs to, the entity layer is an
    /// implementation detail the breadcrumb doesn't surface.
    /// See `hecks_conception/inbox/i577.md` for the spec.
    pub fn format_breadcrumb_phrase(
        &self,
        command_name: &str,
        result: &CommandResult,
    ) -> String {
        let bare_command = command_name.rsplit('.').next().unwrap_or(command_name);

        // Walk aggregates matching the result's type to recover the
        // declared bluebook context. Multiple aggregates may share a
        // name across contexts (the dispatcher disambiguates by
        // qualified address) ; pick the first match whose own
        // commands include the bare name, falling back to a plain
        // name match when no command lookup succeeds.
        let mut domain_name: Option<String> = None;
        for agg in &self.domain.aggregates {
            if agg.name != result.aggregate_type {
                continue;
            }
            let ctx = agg.context.clone()
                .or_else(|| self.domain.category.clone())
                .unwrap_or_else(|| agg.name.clone());
            let owns_command = agg.commands.iter().any(|c| c.name == bare_command)
                || agg.entities.iter().any(|e|
                    e.commands.iter().any(|c| c.name == bare_command));
            if owns_command {
                domain_name = Some(ctx);
                break;
            }
            // Hold the first name-match as a fallback in case no
            // aggregate's commands list owns the bare name (synthetic
            // dispatches, qualified addresses dropping a Context.
            // prefix, etc.).
            if domain_name.is_none() {
                domain_name = Some(ctx);
            }
        }

        // Final fallback : no aggregate IR match at all. Domain
        // defaults to the merged Domain.category when present, else
        // the aggregate name so the slot never empties.
        let domain_name = domain_name.unwrap_or_else(|| {
            self.domain.category.clone()
                .unwrap_or_else(|| result.aggregate_type.clone())
        });

        format!("{}::{}.{}",
            domain_name, result.aggregate_type, bare_command)
    }

    /// Dispatch without firing policy cascades. Used by tests for
    /// SETUP commands so they don't overshoot the test command's
    /// required state. The test command itself dispatches via the
    /// regular `dispatch` so its emit cascade can fire and be
    /// asserted via `expect emits: [...]`.
    pub fn dispatch_isolated(
        &mut self,
        command_name: &str,
        attrs: HashMap<String, Value>,
    ) -> Result<CommandResult, RuntimeError> {
        let result = command_dispatch::dispatch(self, command_name, attrs)?;
        if let Some(ref event) = result.event {
            for proj in &mut self.projections {
                proj.apply(event);
            }
        }
        Ok(result)
    }

    /// Inject a synthetic event into the runtime — drive PMs and
    /// policies as if a command had emitted it, without going through
    /// the full command-dispatch path.
    ///
    /// This is the substrate the PM loop driver uses to fire cadence
    /// events (BodyPulse, HeartTick, etc.) at fixed intervals : the
    /// daemon ticks, calls this with a fresh Event, the PM engine
    /// reacts, dispatches cascade, persistence happens — same machinery
    /// as a real command's emit, just with the upstream command stripped.
    ///
    /// Bus listeners + history capture the event ; projections are
    /// not updated (no aggregate state changed). Returns nothing —
    /// callers wanting cascade results should use `dispatch`.
    pub fn publish_synthetic_event(&mut self, event: Event) {
        self.event_bus.publish(event.clone());
        let result = CommandResult {
            aggregate_id: event.aggregate_id.clone(),
            aggregate_type: event.aggregate_type.clone(),
            event: Some(event),
            // Synthetic events carry no command — no aggregate state changed,
            // so there are no event-sourcing deltas to append.
            deltas: Vec::new(),
        };
        self.drain_policies(&result);
    }

    /// i221 — scan every loaded hecksagon for an `adapter :llm`
    /// declaration whose effective trigger target matches the just-
    /// dispatched `Aggregate.Command` ; for each match, substitute
    /// the prompt template from the upstream state + attrs, call the
    /// resolved provider, and chain the response as a `dispatch_cascade`
    /// into `response_into_target` carrying `response_into_attr`.
    ///
    /// Adapter resolution is by exact target-string match. The IR
    /// holds `trigger_on` (i228) for the firing target and
    /// `response_into_target` for the response routing target. When
    /// `trigger_on` is None the runtime falls back to
    /// `response_into_target` so the historical self-triggering shape
    /// (trigger == response) keeps working without per-adapter
    /// declaration. We compare against `Aggregate.Command`
    /// reconstructed from `result.aggregate_type` + `command_name`.
    /// Adapters with no effective trigger (both fields None) are inert
    /// — just parse-time descriptors — and are skipped silently.
    fn resolve_llm_adapters(&mut self, result: &CommandResult, command_name: &str) {
        let mut fired: std::collections::HashSet<String> = std::collections::HashSet::new();
        self.resolve_llm_adapters_with_excluded(result, command_name, &mut fired);
    }

    /// gap3 (i220-3) helper — `fired` is the set of adapter NAMES that
    /// have already run in this dispatch chain. The cascade-of-cascade
    /// recursion (an :llm response landing on a different command that
    /// itself triggers another :llm adapter) skips any adapter already
    /// in the set, which prevents infinite loops when an adapter's
    /// effective_trigger matches its own response_into_target (the
    /// historical default trigger=response shape, which the very-first
    /// :llm wiring relied on).
    fn resolve_llm_adapters_with_excluded(
        &mut self,
        result: &CommandResult,
        command_name: &str,
        fired: &mut std::collections::HashSet<String>,
    ) {
        // KEYSTONE GATE (slice 1) — when HECKS_REPLY_OOP_LLM is set, the
        // OUT-OF-PROCESS llm effect path (effect binding -> OutboundEvent ->
        // drain_outbound_to_quiescence) owns llm completion. Suppress the
        // in-process LlmAdapter-struct path so the two never both fire and
        // double-produce the verdict. Gate OFF (default) keeps this in-process
        // path as the proven fallback. See docs/driven_port_keystone_api.md.
        if std::env::var("HECKS_REPLY_OOP_LLM").is_ok() {
            return;
        }
        let debug_llm = std::env::var("HECKS_DEBUG_LLM").is_ok();
        if debug_llm {
            eprintln!("[llm:debug] resolve_llm_adapters cmd={} agg_type={} hecksagons={} providers={} fired={}",
                command_name, result.aggregate_type, self.hecksagons.len(), self.llm_providers.len(), fired.len());
        }
        if self.hecksagons.is_empty() {
            if debug_llm { eprintln!("[llm:debug] no hecksagons — returning"); }
            return;
        }
        let bare_command = command_name.rsplit('.').next().unwrap_or(command_name);
        let target = format!("{}.{}", result.aggregate_type, bare_command);
        if debug_llm { eprintln!("[llm:debug] target={}", target); }

        // Snapshot adapters that match — we need to walk hecksagons
        // by ref but mutate self.repositories/etc. via dispatch_cascade
        // afterward, so collect the adapter clones first. i228 — match
        // on the effective trigger (trigger_on || response_into_target)
        // so PM-cascade-only adapters fire on a ProduceX command while
        // routing the LLM reply into a separate RecordX command. gap3
        // (i220-3) — also exclude adapters in `fired` to break the
        // cascade-of-cascade loop when trigger == response.
        let adapters: Vec<crate::hecksagon_ir::LlmAdapter> = self.hecksagons.iter()
            .flat_map(|h| h.llm_adapters.iter())
            .filter(|la| la.effective_trigger() == Some(target.as_str()))
            .filter(|la| !fired.contains(&la.name))
            .cloned()
            .collect();
        if debug_llm {
            eprintln!("[llm:debug] matched {} adapters (out of {} total in hecksagons)",
                adapters.len(),
                self.hecksagons.iter().map(|h| h.llm_adapters.len()).sum::<usize>());
        }
        if adapters.is_empty() { return; }

        // Snapshot upstream state for placeholder substitution.
        let state_clone: Option<AggregateState> = self
            .find(&result.aggregate_type, &result.aggregate_id)
            .cloned();

        // Build the attrs map (string-shaped) from the upstream state
        // PLUS every other aggregate's latest state (i218 cross-aggregate
        // scaffolder gap). The lucid_dream :lucid_observe template
        // references {{text_fr}} which lives on Dream, not LucidDream
        // — without cross-aggregate access the substitution silently
        // failed and Claude received literal {{text_fr}} markers.
        //
        // Resolution order : prefixed forms ({{Dream_text_fr}}) first,
        // then bare ({{text_fr}}) so prefixed wins on collision. Bare
        // gets last-write-wins across aggregates, which is fine for
        // singleton aggregates (each field is unique-ish) and harmless
        // when callers reach for the prefixed form.
        let mut attrs: HashMap<String, String> = HashMap::new();
        // Cross-aggregate fields with prefixed keys, plus bare keys
        // for cross-aggregate references (last-write-wins across
        // aggregates). The dispatched aggregate's state then writes
        // over both — its fields are the most specific source.
        let agg_names: Vec<String> = self.repositories.keys().cloned().collect();
        for agg_name in &agg_names {
            let states: Vec<AggregateState> = self.repositories.get(agg_name)
                .map(|r| r.all().into_iter().cloned().collect())
                .unwrap_or_default();
            if let Some(latest) = states.last() {
                for (k, v) in &latest.fields {
                    attrs.insert(format!("{}_{}", agg_name, k), v.to_string());
                    if agg_name != &result.aggregate_type {
                        attrs.entry(k.clone()).or_insert_with(|| v.to_string());
                    }
                }
            }
        }
        // Upstream (dispatched) aggregate's state wins on bare-name keys.
        if let Some(s) = state_clone.as_ref() {
            for (k, v) in &s.fields {
                attrs.insert(k.clone(), v.to_string());
            }
        }

        for adapter in &adapters {
            // Mark this adapter as fired BEFORE the cascade so a
            // recursive resolve sees it in the exclude set. The
            // dispatch_cascade can transitively land on the same
            // target ; without the pre-mark, we'd re-enter for the
            // historical trigger==response case.
            fired.insert(adapter.name.clone());

            // Take ownership of the providers map briefly so we can
            // pass an immutable borrow to the dispatcher without
            // tripping the multi-borrow rule on self. The runtime
            // still owns the providers — we just hand them through.
            let outcome = {
                let providers = &self.llm_providers;
                let providers_arg = if providers.is_empty() { None } else { Some(providers) };
                llm_dispatcher::call(adapter, state_clone.as_ref(), &attrs, providers_arg)
            };

            let result_data = match outcome {
                llm_dispatcher::LlmOutcome::Completed(r) => r,
                llm_dispatcher::LlmOutcome::Skipped(_)   => continue,
            };

            // Chain the response as a cascade dispatch. The target is
            // `response_into_target` (Aggregate.Command) ; the kwarg
            // name is `response_into_attr` ; the value is the
            // response text.
            let (target_agg, target_cmd) = match adapter.response_into_target.as_deref()
                .and_then(llm_dispatcher::split_target) {
                Some(p) => p,
                None    => continue,
            };
            let attr_name = match adapter.response_into_attr.as_deref() {
                Some(s) if !s.is_empty() => s.to_string(),
                _ => continue,
            };

            let mut chain_attrs: HashMap<String, Value> = HashMap::new();
            chain_attrs.insert(attr_name, Value::Str(result_data.response_text.clone()));
            let cmd_qualified = format!("{}.{}", target_agg, target_cmd);
            let cascade_outcome = command_dispatch::dispatch_cascade(
                self,
                &cmd_qualified,
                chain_attrs,
                &result.aggregate_type,
                &result.aggregate_id,
            );
            // gap3 (i220-3) — chain LLM resolution on the response cascade
            // so a second adapter whose effective_trigger matches the
            // response-target command fires too. Concretely : the
            // :dream_image adapter cascades into Dream.RecordImage(text_fr:),
            // which is exactly the trigger of the :dream_translate adapter
            // (response_into Dream.RecordImage with attr text_en — its
            // effective_trigger falls back to the same target). Without
            // this recursion, text_en stays empty in production. The chain
            // is finite because the `fired` exclude-set tracks adapter
            // names across the recursion : an adapter whose trigger ==
            // response (the historical self-cascading shape) only fires
            // once per dispatch tree.
            if let Ok(inner_result) = cascade_outcome {
                self.resolve_llm_adapters_with_excluded(
                    &inner_result, &cmd_qualified, fired,
                );
            }
        }
    }

    /// i551 — `:claude_tool` adapter resolver. Sibling of
    /// `resolve_llm_adapters` for the io-adapter family that binds
    /// `Tools.X` dispatches to native primitives (shell, edit, read,
    /// write, grep, glob). For each adapter declared in a loaded
    /// hecksagon whose `command` option matches the just-dispatched
    /// `Aggregate.Command`, the runtime reads the aggregate state,
    /// stringifies it into `attrs`, and calls
    /// `claude_tool_dispatcher::dispatch`.
    ///
    /// After the kernel-floor primitive returns, the resolver chains
    /// the `ClaudeToolResult` back into the aggregate via a follow-on
    /// `dispatch_cascade` into the adapter's `result_into` target
    /// (typically `Tools.RecordResult`). The cascade carries the
    /// originating invocation `id`, the `tool` kind, captured
    /// `output`, `exit_code`, and `ok` flag — so the outcome becomes
    /// a first-class event (ResultRecorded) the runtime can react to
    /// instead of just a stderr line. The stderr log is preserved for
    /// debug visibility.
    fn resolve_claude_tool_adapters(
        &mut self,
        result: &CommandResult,
        command_name: &str,
        dispatch_attrs: &HashMap<String, Value>,
    ) {
        if self.hecksagons.is_empty() { return; }
        let debug = std::env::var("HECKS_DEBUG_CLAUDE_TOOL").is_ok();
        let bare_command = command_name.rsplit('.').next().unwrap_or(command_name);
        let target = format!("{}.{}", result.aggregate_type, bare_command);
        if debug {
            eprintln!("[claude_tool:debug] resolve cmd={} target={} hecksagons={}",
                command_name, target, self.hecksagons.len());
        }

        // Snapshot every `:claude_tool` io adapter whose `command`
        // option matches the dispatched target. Values come from
        // parse_options unprocessed — strings still carry their
        // surrounding quotes, symbols still carry their leading colon
        // — so we strip those before matching. `result_into` carries
        // the follow-on cascade target (e.g. "Tools.RecordResult").
        let matched: Vec<(String, String, Option<String>)> = self.hecksagons.iter()
            .flat_map(|h| h.io_adapters.iter())
            .filter(|a| a.kind == "claude_tool")
            .filter_map(|a| {
                let mut cmd: Option<String> = None;
                let mut tool: Option<String> = None;
                let mut result_into: Option<String> = None;
                for (k, v) in &a.options {
                    match k.as_str() {
                        "command"     => cmd = Some(strip_quotes_or_colon(v)),
                        "tool"        => tool = Some(strip_quotes_or_colon(v)),
                        "result_into" => result_into = Some(strip_quotes_or_colon(v)),
                        _ => {}
                    }
                }
                match (cmd, tool) {
                    (Some(c), Some(t)) if c == target => Some((c, t, result_into)),
                    _ => None,
                }
            })
            .collect();
        if debug {
            eprintln!("[claude_tool:debug] matched {} adapter(s) for target={}",
                matched.len(), target);
        }
        if matched.is_empty() { return; }

        // Snapshot the just-dispatched aggregate's state so we can
        // pass its fields to the kernel-floor primitive. The `id`
        // field flows through here so the follow-on RecordResult
        // cascade lands on the same invocation record.
        let state_clone: Option<AggregateState> = self
            .find(&result.aggregate_type, &result.aggregate_id)
            .cloned();
        let mut attrs: HashMap<String, String> = HashMap::new();
        if let Some(s) = state_clone.as_ref() {
            for (k, v) in &s.fields {
                attrs.insert(k.clone(), v.to_string());
            }
        }
        // i559 — overlay the original dispatch attrs on top of the
        // state-derived ones. Tools.Edit's old_string/new_string and
        // Tools.Update's content are event-only payloads (never
        // persisted onto aggregate state per the Tools bluebook), so
        // the state snapshot above is missing them. The dispatch
        // attrs are the only place they exist at this point in the
        // pipeline. Overlay-after-state means the user-supplied
        // values win over any state echo.
        for (k, v) in dispatch_attrs {
            attrs.insert(k.clone(), v.to_string());
        }
        // The aggregate id is authoritative — fall back to the
        // dispatch result if state didn't carry it explicitly.
        let invocation_id = attrs
            .get("id")
            .cloned()
            .unwrap_or_else(|| result.aggregate_id.clone());

        for (_cmd, tool, result_into) in &matched {
            let tool_result = claude_tool_dispatcher::dispatch(tool, &attrs);
            // Preserve the existing debug-visibility log — useful when
            // a cascade fails or the result_into target is missing.
            // i559 — surface the error message inline when ok=false ;
            // previously the message lived only in `tool_result.error`
            // and never made it to stderr, so silent failures showed
            // as `ok=false exit=1 output=""` with no diagnostic.
            let err_tail = match (&tool_result.ok, &tool_result.error) {
                (false, Some(msg)) => format!(" error={:?}", msg),
                _ => String::new(),
            };
            // i622 — runtime outcome line moved to stdout. Same fact
            // as before (one line per claude_tool invocation), now on
            // the single audit stream alongside the other surfaces.
            // The cascade_step log below captures the result_into
            // dispatch outcome separately.
            println!(
                "[{}] [claude_tool:{}] ok={} exit={} output={:?}{}",
                storehouse_log::now_iso8601(),
                tool, tool_result.ok, tool_result.exit_code, tool_result.output, err_tail
            );

            // Chain the result back into the aggregate via the
            // adapter's `result_into` target. Mirror the LLM
            // dispatcher's cascade contract : route through
            // `dispatch_cascade` so depth + cycle protection apply,
            // and pass the originating aggregate as the upstream so
            // the same invocation id is reused.
            let result_into_target = match result_into.as_deref() {
                Some(s) if !s.is_empty() => s,
                _ => {
                    if debug {
                        eprintln!("[claude_tool:debug] no result_into on adapter — skipping cascade");
                    }
                    continue;
                }
            };

            let mut record_attrs: HashMap<String, Value> = HashMap::new();
            record_attrs.insert("id".to_string(), Value::Str(invocation_id.clone()));
            record_attrs.insert("tool".to_string(), Value::Str(tool_result.tool.clone()));
            record_attrs.insert("output".to_string(), Value::Str(tool_result.output.clone()));
            record_attrs.insert("exit_code".to_string(), Value::Int(tool_result.exit_code as i64));
            record_attrs.insert("ok".to_string(), Value::Bool(tool_result.ok));

            let cascade_outcome = command_dispatch::dispatch_cascade(
                self,
                result_into_target,
                record_attrs,
                &result.aggregate_type,
                &result.aggregate_id,
            );
            // i622 — cascade step log. claude_tool result_into chain.
            storehouse_log::cascade_step(
                result_into_target,
                &invocation_id,
                cascade_outcome.is_ok(),
            );
            if debug {
                match &cascade_outcome {
                    Ok(_)  => eprintln!("[claude_tool:debug] cascaded into {} ok", result_into_target),
                    Err(e) => eprintln!("[claude_tool:debug] cascade into {} failed: {:?}", result_into_target, e),
                }
            }
            // Swallow the cascade outcome — failures are observable
            // via the debug eprintln above ; we don't want the
            // tool-side error to bubble through the kernel hook and
            // break the original dispatch's return.
            let _ = cascade_outcome;
        }
    }

    /// [antibody-exempt: rust/src/runtime/mod.rs (resolve_primitive_spawn) —
    ///  kernel-floor primitive leaf for the `Primitive::Process.Spawn`
    ///  bluebook command (adapters-as-bluebook first slice). The spawn
    ///  syscall is irreducible imperative ; the surrounding PROTOCOL
    ///  (fire → run → cascade) is now ordinary bluebook policy/cascade.
    ///  Sibling of exec_dispatcher.rs's existing exemption.]
    ///
    /// The generic process-spawn primitive — the adapters-as-bluebook
    /// floor tile that replaced the retired `resolve_exec_adapters`,
    /// driven by ordinary bluebook policy/cascade instead of a bespoke
    /// per-family resolver. Fires when a `Primitive::Process.Spawn`
    /// command dispatches (whether from a top-level dispatch or from
    /// inside a policy / PM cascade). Reads the literal program string
    /// off the dispatch attrs (`cmd`), runs it to completion via the
    /// kernel-floor exec leaf (`exec_dispatcher::dispatch` — reused
    /// unchanged), and cascades (id, output, exit_code, ok) into the
    /// `result_into` target carried on the same dispatch.
    ///
    /// The cascade join key is the `id` attr the dispatch carried (the
    /// originating invocation id, threaded by the firing policy's
    /// event data) — falling back to the Process record's own id. This
    /// is the SAME contract the `:exec` resolver honours : the outcome
    /// record joins the originating invocation by id.
    ///
    /// `resolve_exec_adapters` is RETIRED. Every former `:exec` binding
    /// is now an ordinary bluebook policy firing this primitive : the
    /// fibroblast repair sweep (`on "SweepRan"`), the Gmail poll
    /// (`on "Inbox.InboxChecked"`), and the process-health sweep + heal
    /// (`on "ProcessMacrophage.Swept"` / `on "ProcessMacrophage.HealRequested"`).
    /// The last two need gap #1b — the aggregate-qualified `on` form —
    /// because `Swept` is emitted by both ProcessMacrophage and the
    /// discipline macrophage and is also consumed by the bare
    /// `MarkHangedOnMissingHeartbeat` policy ; the qualifier fires the
    /// sweeper ONLY for ProcessMacrophage's Swept.
    ///
    /// This is the ONLY new imperative leaf : the spawn syscall.
    fn resolve_primitive_spawn(
        &mut self,
        result: &CommandResult,
        command_name: &str,
        dispatch_attrs: &HashMap<String, Value>,
        trigger_event: Option<&event_bus::Event>,
    ) {
        let bare_command = command_name.rsplit('.').next().unwrap_or(command_name);
        // The primitive matches by aggregate + command, not by a
        // hecksagon binding : the bluebook IS the contract. Anything
        // that dispatches `Process.Spawn` runs the spawn.
        if result.aggregate_type != "Process" || bare_command != "Spawn" {
            return;
        }

        // sprint-14 (storehouse-primitive-conception) — consult the
        // PrimitiveRegistry BEFORE running. The registry's
        // `Storehouse::Primitive` records are the bluebook ground truth
        // for which imperative leaves the runtime carries ; the lookup
        // is logged so a smoke trace can confirm the dispatch routed
        // through it. A miss here is the macrophage's signal that the
        // imperative leaf has no declaration. The hard-coded arm below
        // STAYS in place — the registry is an overlay, not yet a
        // replacement.
        let registry_key = format!("{}.{}", result.aggregate_type, bare_command);
        match self.primitive_registry.lookup(&registry_key) {
            Some(spec) => {
                println!(
                    "[{}] [primitive:registry] routed name={} kind={} impl={}",
                    storehouse_log::now_iso8601(),
                    spec.name, spec.kind, spec.implementation,
                );
            }
            None => {
                println!(
                    "[{}] [primitive:registry] miss name={} — Storehouse::Primitive declaration absent",
                    storehouse_log::now_iso8601(),
                    registry_key,
                );
            }
        }

        let cmd = match dispatch_attrs.get("cmd").map(|v| v.to_string()) {
            Some(c) if !c.is_empty() => c,
            _ => {
                println!(
                    "[{}] [primitive:spawn] skipped — missing cmd attr",
                    storehouse_log::now_iso8601(),
                );
                return;
            }
        };
        let result_into = dispatch_attrs.get("result_into").map(|v| v.to_string());

        // The cascade join key is the `id` the dispatch carried (the
        // originating invocation id), falling back to the Process
        // record's own id. Mirrors the retired :exec resolver's
        // invocation_id contract.
        let invocation_id = dispatch_attrs
            .get("id")
            .map(|v| v.to_string())
            .or_else(|| {
                self.find(&result.aggregate_type, &result.aggregate_id)
                    .and_then(|s| s.fields.get("id").map(|v| v.to_string()))
            })
            .unwrap_or_else(|| result.aggregate_id.clone());

        // Inject the triggering event's payload into the child's
        // environment so the spawned process can read the prompt/id
        // without needing to hit the disk heki (which may be stale
        // when the runtime is warm/in-memory). Generic — passes the
        // whole event, not sidequest-specific fields.
        //
        // sq/policy-cmd-bin-wrappers lifts three commonly-needed
        // fields out of the event payload into top-level env vars so
        // wrappers can read them with a bare `$AGG_ID` rather than
        // parse JSON :
        //   AGG_ID     = ev.aggregate_id  (the join key the Record*
        //                cascade lands back on)
        //   AGG_TYPE   = ev.aggregate_type
        //   EVENT_NAME = ev.name
        // The full payload still rides on STOREHOUSE_TRIGGER_EVENT AND
        // on stdin as JSON so scripts that want the whole event can
        // drain it without re-parsing env.
        let (extra_env, stdin_payload): (Vec<(String, String)>, Option<String>) =
            if let Some(ev) = trigger_event {
                let mut data_map = serde_json::Map::new();
                for (k, v) in &ev.data {
                    data_map.insert(k.clone(), match v {
                        Value::Str(s) => serde_json::json!(s),
                        Value::Int(n) => serde_json::json!(n),
                        Value::Bool(b) => serde_json::json!(b),
                        _ => serde_json::json!(v.to_string()),
                    });
                }
                let payload = serde_json::json!({
                    "name": ev.name,
                    "aggregate_type": ev.aggregate_type,
                    "aggregate_id": ev.aggregate_id,
                    "data": serde_json::Value::Object(data_map),
                });
                let payload_str = payload.to_string();
                (
                    vec![
                        ("STOREHOUSE_TRIGGER_EVENT".to_string(), payload_str.clone()),
                        ("AGG_ID".to_string(), ev.aggregate_id.clone()),
                        ("AGG_TYPE".to_string(), ev.aggregate_type.clone()),
                        ("EVENT_NAME".to_string(), ev.name.clone()),
                    ],
                    Some(payload_str),
                )
            } else {
                (vec![], None)
            };

        let exec_result = exec_dispatcher::dispatch(&cmd, &extra_env, stdin_payload.as_deref());
        let err_tail = match (&exec_result.ok, &exec_result.error) {
            (false, Some(msg)) => format!(" error={:?}", msg),
            _ => String::new(),
        };
        println!(
            "[{}] [primitive:spawn] ok={} exit={} output={:?}{}",
            storehouse_log::now_iso8601(),
            exec_result.ok, exec_result.exit_code, exec_result.output, err_tail
        );

        let result_into_target = match result_into.as_deref() {
            Some(s) if !s.is_empty() => s,
            _ => return,
        };
        let mut record_attrs: HashMap<String, Value> = HashMap::new();
        record_attrs.insert("id".to_string(), Value::Str(invocation_id.clone()));
        record_attrs.insert("output".to_string(), Value::Str(exec_result.output.clone()));
        record_attrs.insert("exit_code".to_string(), Value::Int(exec_result.exit_code as i64));
        record_attrs.insert("ok".to_string(), Value::Bool(exec_result.ok));
        let cascade_outcome = command_dispatch::dispatch_cascade(
            self,
            result_into_target,
            record_attrs,
            &result.aggregate_type,
            &result.aggregate_id,
        );
        storehouse_log::cascade_step(
            result_into_target,
            &invocation_id,
            cascade_outcome.is_ok(),
        );
        let _ = cascade_outcome;
    }

    /// i594 — :mcp adapter resolver. Parallel to
    /// `resolve_claude_tool_adapters`, different adapter family : the
    /// `:mcp` family (declared at
    /// `aggregates/framework/adapter_families/mcp.hecksagon`) carries
    /// `server`, `tool`, `args`, and `result_into` fields plus the
    /// `command` trigger. When a hecksagon-loaded binding's `command`
    /// matches the just-dispatched `Aggregate.Command`, this arm :
    ///
    ///   1. Resolves the `:server` (graceful warn if unregistered ;
    ///      e.g. `:gmail` pending i610's bridge).
    ///   2. Reads the binding's `:args` (a JSON-encoded string per the
    ///      tools.hecksagon convention) and substitutes `{attr}`
    ///      placeholders from upstream state ∪ dispatch attrs.
    ///   3. Calls the kernel-floor `mcp_dispatcher::dispatch` which
    ///      opens a stdio MCP session and runs `tools/call`.
    ///   4. Chains the response into `:result_into` as a
    ///      `dispatch_cascade` carrying `id`, `tool`, `output`,
    ///      `exit_code` (always 0 for MCP), and `ok`.
    ///
    /// HECKS_DEBUG_MCP=1 surfaces the resolution + per-binding fire
    /// trace ; same shape as HECKS_DEBUG_CLAUDE_TOOL.
    fn resolve_mcp_adapters(
        &mut self,
        result: &CommandResult,
        command_name: &str,
        dispatch_attrs: &HashMap<String, Value>,
    ) {
        if self.hecksagons.is_empty() { return; }
        let debug = std::env::var("HECKS_DEBUG_MCP").is_ok();
        let bare_command = command_name.rsplit('.').next().unwrap_or(command_name);
        let target = format!("{}.{}", result.aggregate_type, bare_command);

        // Snapshot every `:mcp` io adapter whose `command` field
        // matches the dispatched target. Strip parser-noise (quotes
        // around strings, leading colon on symbols) before comparing
        // / forwarding. `args` carries the JSON-encoded payload that
        // becomes the MCP `arguments` field after `{attr}` substitution.
        let matched: Vec<(String, String, String, String, Option<String>)> = self.hecksagons.iter()
            .flat_map(|h| h.io_adapters.iter())
            .filter(|a| a.kind == "mcp")
            .filter_map(|a| {
                let mut cmd: Option<String> = None;
                let mut server: Option<String> = None;
                let mut tool: Option<String> = None;
                let mut args: String = String::new();
                let mut result_into: Option<String> = None;
                for (k, v) in &a.options {
                    match k.as_str() {
                        "command"     => cmd = Some(strip_quotes_or_colon(v)),
                        "server"      => server = Some(strip_quotes_or_colon(v)),
                        "tool"        => tool = Some(strip_quotes_or_colon(v)),
                        "args"        => args = strip_quotes_or_colon(v),
                        "result_into" => result_into = Some(strip_quotes_or_colon(v)),
                        _ => {}
                    }
                }
                match (cmd, server, tool) {
                    (Some(c), Some(s), Some(t)) if c == target => {
                        Some((c, s, t, args, result_into))
                    }
                    _ => None,
                }
            })
            .collect();
        if debug {
            eprintln!("[mcp:debug] resolve cmd={} target={} matched={}",
                command_name, target, matched.len());
        }
        if matched.is_empty() { return; }

        // Build the attrs map (state ∪ dispatch) for placeholder
        // substitution — same shape the claude_tool arm uses.
        let state_clone: Option<AggregateState> = self
            .find(&result.aggregate_type, &result.aggregate_id)
            .cloned();
        let mut attrs: HashMap<String, String> = HashMap::new();
        if let Some(s) = state_clone.as_ref() {
            for (k, v) in &s.fields {
                attrs.insert(k.clone(), v.to_string());
            }
        }
        for (k, v) in dispatch_attrs {
            attrs.insert(k.clone(), v.to_string());
        }
        let invocation_id = attrs
            .get("id")
            .cloned()
            .unwrap_or_else(|| result.aggregate_id.clone());

        for (_cmd, server, tool, args_raw, result_into) in &matched {
            // Parse + substitute args before the world-server check so the
            // resolved payload (tool name, substituted args, result_into) can
            // be forwarded into the transport-C event emit inside
            // `resolve_world_server`. JSON parse failure skips the whole
            // binding — no point resolving the server for an unparseable args.
            let args_value: serde_json::Value = if args_raw.is_empty() {
                serde_json::Value::Object(Default::default())
            } else {
                match serde_json::from_str(args_raw) {
                    Ok(v) => v,
                    Err(e) => {
                        eprintln!(
                            "[mcp:warn] adapter for {} :args is not JSON ({}) — skipping",
                            target, e
                        );
                        continue;
                    }
                }
            };
            let args_substituted = mcp_dispatcher::substitute_value(args_value, &attrs);

            // i610 — resolve the server from the project's `*.world` files
            // (attached at boot into `world_servers`). Emits an
            // `mcp_dispatch_requested` event on the storehouse follow stream
            // and continues — the harness-side subscriber owns the transport.
            // See `adapter_resolution::mcp::resolve_world_server`.
            if crate::adapter_resolution::mcp::resolve_world_server(
                self, server, tool, &args_substituted,
                result_into.as_deref(), &invocation_id, &target,
            ) {
                continue;
            }
            // i594 — graceful guard for servers neither world-declared nor
            // locally spawnable. Log + skip rather than panic so the
            // dispatch still lands in the heki and the cascade proceeds.
            if !mcp_dispatcher::server_is_registered(server) {
                eprintln!(
                    "[mcp:warn] adapter for {} declares server={} which is neither \
                    world-declared nor a spawnable server. Dispatch recorded ; MCP call skipped.",
                    target, server
                );
                continue;
            }

            let tool_result = mcp_dispatcher::dispatch(server, tool, &args_substituted);
            let err_tail = if tool_result.error.is_empty() {
                String::new()
            } else {
                format!(" error={:?}", tool_result.error)
            };
            eprintln!(
                "[mcp:{}] server={} ok={} output={:?}{}",
                tool, server, !tool_result.is_error, tool_result.text, err_tail
            );

            let result_into_target = match result_into.as_deref() {
                Some(s) if !s.is_empty() => s,
                _ => {
                    if debug {
                        eprintln!("[mcp:debug] no result_into on adapter — skipping cascade");
                    }
                    continue;
                }
            };

            let output_str = if tool_result.text.is_empty() {
                tool_result.structured.clone()
            } else {
                tool_result.text.clone()
            };

            let mut record_attrs: HashMap<String, Value> = HashMap::new();
            record_attrs.insert("id".to_string(), Value::Str(invocation_id.clone()));
            record_attrs.insert("tool".to_string(), Value::Str(tool.clone()));
            record_attrs.insert("output".to_string(), Value::Str(output_str));
            record_attrs.insert("exit_code".to_string(), Value::Int(0));
            record_attrs.insert("ok".to_string(), Value::Bool(!tool_result.is_error));

            let cascade_outcome = command_dispatch::dispatch_cascade(
                self,
                result_into_target,
                record_attrs,
                &result.aggregate_type,
                &result.aggregate_id,
            );
            if debug {
                match &cascade_outcome {
                    Ok(_)  => eprintln!("[mcp:debug] cascaded into {} ok", result_into_target),
                    Err(e) => eprintln!("[mcp:debug] cascade into {} failed: {:?}", result_into_target, e),
                }
            }
            let _ = cascade_outcome;
        }
    }

    /// i220 sub-gap 5 — compute-adapter resolver. Mirror of
    /// `resolve_llm_adapters` for the `:compute` family. Scans every
    /// loaded hecksagon for an `adapter :compute` declaration whose
    /// effective trigger target matches the just-dispatched
    /// `Aggregate.Command` ; for each match, invokes the named
    /// function from the `compute_functions` registry and chains the
    /// returned String as a `dispatch_cascade` into
    /// `response_into_target` carrying `response_into_attr`.
    ///
    /// Same fallback shape as the LLM resolver : adapters with
    /// neither `trigger_on` nor `response_into_target` are inert
    /// descriptors and are skipped silently. The `fired` exclude-set
    /// breaks self-cascade loops (an adapter whose trigger matches
    /// its own response target only fires once per dispatch tree).
    fn resolve_compute_adapters(&mut self, result: &CommandResult, command_name: &str) {
        let mut fired: std::collections::HashSet<String> = std::collections::HashSet::new();
        self.resolve_compute_adapters_with_excluded(result, command_name, &mut fired);
    }

    fn resolve_compute_adapters_with_excluded(
        &mut self,
        result: &CommandResult,
        command_name: &str,
        fired: &mut std::collections::HashSet<String>,
    ) {
        let debug = std::env::var("HECKS_DEBUG").is_ok();
        if debug {
            eprintln!("[compute:debug] resolve_compute_adapters cmd={} agg_type={} hecksagons={} fired={}",
                command_name, result.aggregate_type, self.hecksagons.len(), fired.len());
        }
        if self.hecksagons.is_empty() {
            return;
        }
        let bare_command = command_name.rsplit('.').next().unwrap_or(command_name);
        let target = format!("{}.{}", result.aggregate_type, bare_command);

        // Snapshot adapters that match — same pattern the LLM
        // resolver uses (walk hecksagons by ref then mutate self
        // through dispatch_cascade after).
        let adapters: Vec<crate::hecksagon_ir::ComputeAdapter> = self.hecksagons.iter()
            .flat_map(|h| h.compute_adapters.iter())
            .filter(|ca| ca.effective_trigger() == Some(target.as_str()))
            .filter(|ca| !fired.contains(&ca.name))
            .cloned()
            .collect();
        if debug {
            eprintln!("[compute:debug] matched {} adapters target={}", adapters.len(), target);
        }
        if adapters.is_empty() { return; }

        // Snapshot upstream state for the function call.
        let state_clone: Option<AggregateState> = self
            .find(&result.aggregate_type, &result.aggregate_id)
            .cloned();

        // Build the attrs map (string-shaped) from the upstream
        // state — same projection the LLM resolver uses, but
        // limited to the dispatched aggregate (compute functions
        // generally don't need cross-aggregate scaffolding ; if
        // they ever do we'll lift the bigger projection).
        let mut attrs: HashMap<String, String> = HashMap::new();
        if let Some(s) = state_clone.as_ref() {
            for (k, v) in &s.fields {
                attrs.insert(k.clone(), v.to_string());
            }
        }

        let data_dir = self.data_dir.clone();
        for adapter in &adapters {
            fired.insert(adapter.name.clone());

            let outcome = compute_dispatcher::call(
                adapter,
                state_clone.as_ref(),
                &attrs,
                data_dir.as_deref(),
            );
            let result_data = match outcome {
                compute_dispatcher::ComputeOutcome::Completed(r) => r,
                compute_dispatcher::ComputeOutcome::Skipped(_)   => continue,
            };

            let (target_agg, target_cmd) = match adapter.response_into_target.as_deref()
                .and_then(compute_dispatcher::split_target) {
                Some(p) => p,
                None    => continue,
            };
            let attr_name = match adapter.response_into_attr.as_deref() {
                Some(s) if !s.is_empty() => s.to_string(),
                _ => continue,
            };

            let mut chain_attrs: HashMap<String, Value> = HashMap::new();
            chain_attrs.insert(attr_name, Value::Str(result_data.response_text.clone()));
            let cmd_qualified = format!("{}.{}", target_agg, target_cmd);
            let cascade_outcome = command_dispatch::dispatch_cascade(
                self,
                &cmd_qualified,
                chain_attrs,
                &result.aggregate_type,
                &result.aggregate_id,
            );
            // Recurse through the compute resolver so a chain of
            // :compute adapters all populating context-fields fires
            // end-to-end before the LLM hook lands. The `fired`
            // exclude-set bounds the recursion.
            if let Ok(inner_result) = cascade_outcome {
                self.resolve_compute_adapters_with_excluded(
                    &inner_result, &cmd_qualified, fired,
                );
            }
        }
    }

    pub fn find(&self, aggregate_name: &str, id: &str) -> Option<&AggregateState> {
        // Exact-key fast path — when the caller passes either the bare
        // name (single-context corpus) or a fully-qualified
        // `Context::Name` key (post-i142), match it directly.
        if let Some(repo) = self.repositories.get(aggregate_name) {
            if let Some(state) = repo.find(id) {
                return Some(state);
            }
        }
        // Context-disambiguation path — when multiple contexts declare
        // an aggregate with the same name (e.g. self/Conversation,
        // capabilities/cloudflare_deploy/MiettePhone::Conversation),
        // repo_lookup_key picks
        // a first hash-iter match nondeterministically. Walk every
        // key ending with `::<name>` and return the FIRST one whose
        // store actually carries the id — the id itself disambiguates
        // which context the dispatch landed in.
        let suffix = format!("::{}", aggregate_name);
        for (key, repo) in &self.repositories {
            if key.ends_with(&suffix) {
                if let Some(state) = repo.find(id) {
                    return Some(state);
                }
            }
        }
        None
    }

    pub fn all(&self, aggregate_name: &str) -> Vec<&AggregateState> {
        match repo_lookup_key(&self.repositories, aggregate_name) {
            Some(key) => self.repositories.get(&key).map(|repo| repo.all()).unwrap_or_default(),
            None => Vec::new(),
        }
    }

    /// Resolve a hexagon adapter (by its declared name, e.g. "Stripe") to its
    /// standalone handler program path and family, walking the loaded
    /// hecksagons' adapter declarations. The standalone adapter HOST
    /// (`storehouse host`) uses this to learn which program to exec for a
    /// delivery whose `adapter` field names this adapter. Returns the FIRST
    /// match (adapter names are unique across a conception). `handler` is
    /// empty for in-process adapters (heki/memory) — those never shell out.
    pub fn adapter_handler(&self, adapter_name: &str) -> Option<(String, String)> {
        for hex in &self.hecksagons {
            for a in &hex.adapters {
                if a.name == adapter_name {
                    return Some((a.handler.clone(), a.family.clone()));
                }
            }
        }
        None
    }

    /// The config FIELDS a family declares — `(name, source)` pairs, source
    /// being `direct` | `env` | `secret` (empty defaults to direct). The
    /// standalone host (`run_host::config::map_config`) consults these to map a
    /// `.world` block onto the handler child's env per the field-source
    /// convention. Walks the loaded hecksagons' families (sibling of
    /// `adapter_handler`) ; returns empty when the family isn't found.
    pub fn family_fields(&self, family: &str) -> Vec<(String, String)> {
        for hex in &self.hecksagons {
            for f in &hex.families {
                if f.name == family {
                    return f
                        .fields
                        .iter()
                        .map(|fld| (fld.name.clone(), fld.source.clone()))
                        .collect();
                }
            }
        }
        Vec::new()
    }

    /// The per-adapter `.world` config (key→value pairs) the host folds into
    /// the handler child's environment, AFTER `run_host::config::map_config`
    /// applies the family field-source convention. Empty when no `.world` binds
    /// this adapter (the demo case — the handler then takes its built-in
    /// default path).
    pub fn adapter_world_config(&self, adapter_name: &str) -> Vec<(String, String)> {
        // The pizzas-form `Domain::Agg.verb("Adapter") do … end` lands in world
        // CONFIGS keyed by the LOWERCASED adapter name (config_for : "Stripe" ->
        // "stripe", "ElevenLabs" -> "elevenlabs"). Fall back to the older
        // `adapter "Name" do …` adapter_bindings form (exact name).
        let lname = adapter_name.to_lowercase();
        if let Some(c) = self.world_configs.iter().find(|c| c.name == lname) {
            return c.values.clone();
        }
        self.world_adapter_bindings
            .iter()
            .find(|b| b.name == adapter_name)
            .map(|b| b.values.clone())
            .unwrap_or_default()
    }

    /// PRIMARY-ADAPTER SYNCHRONOUS WAIT (driving-side, Cockburn) — drain the
    /// verdict-bearing OutboundEvent deliveries INLINE, to quiescence, reusing
    /// run_host's primitive (Claim -> exec handler BLOCKING + verdict-capturing
    /// -> dispatch the verdict -> the verdict RE-ENTERS the core, which may emit
    /// more effects -> loop). Returns the number of deliveries drained.
    ///
    /// This is the keystone the serve/dispatch boundary calls (gated by
    /// HECKS_REPLY_OOP_LLM) so a synchronous caller gets the effect's result
    /// back. The CORE never blocks : it has already returned by the time this
    /// runs ; the WAIT is a primary-adapter concern, not a driven-port one.
    ///
    /// Discipline (see docs/driven_port_keystone_api.md) :
    ///   - Claims ONLY verdict-bearing deliveries (success_command non-empty).
    ///     Fire-and-forget (tts) is LEFT for the detach pump
    ///     (pump_outbound_events) — never claimed here, so a slow playback can't
    ///     block the wait and a verdict k=v is never lost to the detach pump's
    ///     Stdio::null().
    ///   - Handler-less deliveries are LEFT PENDING (not claimed, not failed) —
    ///     mirrors pump_outbound_events, NOT run_host_pass (whose mark_failed on
    ///     handler-less would loop forever under this quiescence wrapper).
    ///   - Claim's `given status == pending` is the at-least-once idempotency
    ///     guard : a replay after MarkDelivered finds status != pending, Claim
    ///     errors, the handler is not re-exec'd, the verdict lands exactly once.
    ///   - Bounded by MAX_ITERS (total drain budget). An exec error within the
    ///     budget -> MarkFailed (last_error) -> the delivery returns to pending
    ///     for a bounded retry / dead-letter (compensate-forward).
    pub fn drain_outbound_to_quiescence(&mut self) -> usize {
        const MAX_ITERS: usize = 256;
        if !self.domain.aggregates.iter().any(|a| a.name == "OutboundEvent") {
            return 0;
        }
        let root = self.aggregates_root.clone().unwrap_or_default();

        struct Pending {
            delivery_id: String,
            adapter: String,
            payload: String,
            success_command: String,
            failure_command: String,
        }
        fn fld(s: &AggregateState, k: &str) -> String {
            s.get(k).as_str().unwrap_or("").to_string()
        }

        let mut drained = 0usize;
        let mut iters = 0usize;
        loop {
            iters += 1;
            if iters > MAX_ITERS {
                eprintln!("[drain_outbound_to_quiescence] budget reached — stopping");
                break;
            }
            // Snapshot pending VERDICT-BEARING deliveries with a built handler.
            let pending: Vec<Pending> = self
                .all("OutboundEvent")
                .into_iter()
                .filter(|s| fld(s, "status") == "pending")
                .filter(|s| !fld(s, "success_command").is_empty())
                .map(|s| Pending {
                    delivery_id: fld(s, "delivery_id"),
                    adapter: fld(s, "adapter"),
                    payload: fld(s, "payload"),
                    success_command: fld(s, "success_command"),
                    failure_command: fld(s, "failure_command"),
                })
                .collect();

            // Keep only deliveries whose adapter has a built handler binary —
            // a handler-less / unbuilt-binary delivery is LEFT PENDING for its
            // in-runtime path (mirrors pump_outbound_events ; never mark_failed).
            let actionable: Vec<Pending> = pending
                .into_iter()
                .filter(|d| {
                    let (handler, _) = self.adapter_handler(&d.adapter).unwrap_or_default();
                    if handler.is_empty() {
                        return false;
                    }
                    let p = std::path::Path::new(&handler);
                    let abs = if p.is_absolute() {
                        handler.clone()
                    } else if !root.is_empty() {
                        std::path::Path::new(&root).join(&handler).to_string_lossy().into_owned()
                    } else {
                        handler.clone()
                    };
                    std::path::Path::new(&abs).exists()
                })
                .collect();

            if actionable.is_empty() {
                break; // quiescent
            }

            for d in actionable {
                // Claim BEFORE exec — the at-least-once guard. A second drainer
                // (or the daemon) Claiming the same delivery errors here : skip.
                let mut claim = HashMap::new();
                claim.insert("delivery_id".to_string(), Value::Str(d.delivery_id.clone()));
                if self.dispatch("Claim", claim).is_err() {
                    continue;
                }
                drained += 1;

                // Resolve handler + fold the .world config onto the canonical env.
                let (handler, family) = self.adapter_handler(&d.adapter).unwrap_or_default();
                let handler_path = {
                    let p = std::path::Path::new(&handler);
                    if p.is_absolute() {
                        handler.clone()
                    } else if !root.is_empty() {
                        std::path::Path::new(&root).join(&handler).to_string_lossy().into_owned()
                    } else {
                        handler.clone()
                    }
                };
                let world = self.adapter_world_config(&d.adapter);
                let env = adapter_env::map_config(
                    &family, &world, &self.family_fields(&family),
                );

                // EXEC the handler BLOCKING, capturing the k=v verdict + exit
                // branch — run_host's primitive, reused verbatim.
                match crate::run_host::exec::run_handler(&handler_path, &d.payload, &env) {
                    Err(e) => {
                        // Spawn / I/O error — a retryable transport failure, not a
                        // verdict. MarkFailed returns it to pending (dead-letter on
                        // budget exhaustion). last_error captured.
                        let mut mf = HashMap::new();
                        mf.insert("delivery_id".to_string(), Value::Str(d.delivery_id.clone()));
                        mf.insert("error".to_string(), Value::Str(e));
                        let _ = self.dispatch("MarkFailed", mf);
                    }
                    Ok(outcome) => {
                        let verdict = if outcome.success {
                            &d.success_command
                        } else {
                            &d.failure_command
                        };
                        if !verdict.is_empty() {
                            // Thread the handler's stdout k=v pairs into the verdict
                            // command. THE VERDICT RE-ENTERS THE CORE — it may emit
                            // more effects, drained on the next loop iteration
                            // (drain-to-quiescence).
                            let mut vattrs: HashMap<String, Value> = HashMap::new();
                            for (k, v) in &outcome.verdict_pairs {
                                vattrs.insert(k.clone(), Value::Str(v.clone()));
                            }
                            let _ = self.dispatch(verdict, vattrs);
                        }
                        // Reached a verdict == HANDLED -> MarkDelivered (terminal).
                        let mut md = HashMap::new();
                        md.insert("delivery_id".to_string(), Value::Str(d.delivery_id.clone()));
                        let _ = self.dispatch("MarkDelivered", md);
                    }
                }
            }
        }
        drained
    }

    /// Drain policy triggers recursively — each triggered command
    /// can emit events that trigger more policies. This is how
    /// EnterSleep cascades through 8 dream cycles to WakeUp.
    ///
    /// When the triggered command has a self-reference to the same
    /// aggregate the event came from, inject the upstream aggregate_id
    /// under that ref's name. Without this, downstream cascades stop
    /// at any self-ref command (the dispatch errors with missing
    /// self-referencing id), leaving aggregates stuck mid-pipeline.
    /// The behaviors generator's static cascade prediction
    /// (cascade::cascade_emits) assumes the runtime honors these
    /// triggers — so this injection is what makes the prediction true.
    pub(crate) fn drain_policies(&mut self, result: &CommandResult) {
        if let Some(ref event) = result.event {
            // Drive process_managers + dispatch their declared commands.
            // Each PMTrigger carries dispatches: Vec<String> populated
            // from the handler's declarative `dispatch "..."` lines ;
            // route through cascade dispatcher so policies + nested PMs
            // + downstream emits all fire normally.
            let pm_triggers = self.pm_engine.react(event);
            for t in pm_triggers.clone() {
                // Phase D — persist the new instance state immediately
                // after each transition so the next subprocess fork sees
                // it. Best-effort : a failed write doesn't abort the
                // cascade ; the audit trail captures it via heki's
                // dispatch context.
                let _ = self.pm_engine.persist_instance(
                    &t.pm_name,
                    &t.correlation_id,
                    self.data_dir.as_deref(),
                );

                // Phase 2.c — apply the handler's set_specs BEFORE the
                // dispatches so that `from_pm(:attr)` reads inside the
                // same handler's dispatch with-spec see the freshly
                // written value. This matches the legacy proc form
                // where the action body assigned `pm.attributes[:x]`
                // at the top, then returned `{ commands: [...] }`
                // referring to those same values.
                let set_pairs = self.pm_set_pairs(&t, event);
                for (attr, value) in set_pairs {
                    self.pm_engine
                        .apply_set(&t.pm_name, &t.correlation_id, &attr, value);
                }
                // Re-persist after the set so the attributes hash
                // round-trips with the new values. Best-effort, like
                // the state-only persist above.
                let _ = self.pm_engine.persist_instance(
                    &t.pm_name,
                    &t.correlation_id,
                    self.data_dir.as_deref(),
                );

                for dispatched in &t.dispatches {
                    // i221-B — sweep dispatch. When the DispatchSpec
                    // carries `for_each: Some(spec)`, look up the
                    // named query (Aggregate.query_name) in the
                    // domain IR, run it against the in-memory
                    // repository to enumerate matching records, and
                    // dispatch one cascade per record threading the
                    // record's fields as `iter_data`. `from_iter
                    // (:field)` in the with-spec resolves against
                    // each record. When `for_each` is `None` (the
                    // bare-dispatch path), the loop body runs once
                    // with `iter_data = None` — same shape as before.
                    let iter_records: Vec<HashMap<String, Value>> = match &dispatched.for_each {
                        Some(spec) => {
                            // i221-C — resolve the swept query's inputs
                            // against the event so the sweep filters.
                            let mut q_attrs: HashMap<String, String> = HashMap::new();
                            for (k, vspec) in &spec.query_inputs {
                                if let Some(v) = self.evaluate_value_spec(
                                    vspec, event, &t.pm_name, &t.correlation_id, None,
                                ) {
                                    q_attrs.insert(k.clone(), v.to_string());
                                }
                            }
                            self.sweep_records(spec, &q_attrs)
                        }
                        None => vec![HashMap::new()],
                    };
                    let is_sweep = dispatched.for_each.is_some();

                    for record in &iter_records {
                        // Phase 2.b (pm-dispatch-enrichment) —
                        // evaluate each ValueSpec in the with_spec
                        // at dispatch time. Order : with_spec
                        // resolution first (so an explicit
                        // `name: "body"` literal beats refs the
                        // inject_refs heuristic might guess), then
                        // upstream-ref injection fills in
                        // everything still unset.
                        let mut data = std::collections::HashMap::new();
                        let iter_arg = if is_sweep { Some(record) } else { None };
                        for (key, spec) in &dispatched.with_spec {
                            if let Some(v) = self.evaluate_value_spec(
                                spec,
                                event,
                                &t.pm_name,
                                &t.correlation_id,
                                iter_arg,
                            ) {
                                data.insert(key.clone(), v);
                            }
                        }
                        self.inject_refs(
                            &dispatched.command_name,
                            &event.aggregate_type,
                            &event.aggregate_id,
                            &mut data,
                        );
                        // Clone before the move so the process-spawn
                        // primitive hook below sees the dispatch attrs
                        // (a PM could also drive Primitive::Process.Spawn).
                        let cascade_attrs = data.clone();
                        let inner = command_dispatch::dispatch_cascade(
                            self,
                            &dispatched.command_name,
                            data,
                            &event.aggregate_type,
                            &event.aggregate_id,
                        );
                        // i622 — cascade step log. PM-driven cascade.
                        storehouse_log::cascade_step(
                            &dispatched.command_name,
                            &event.aggregate_id,
                            inner.is_ok(),
                        );
                        if let Ok(inner_result) = inner {
                            self.drain_policies(&inner_result);
                            // i220 sub-gap 5 — fire the :compute hook
                            // on PM cascade dispatches first, so the
                            // chained context-populated state is
                            // visible when the LLM hook reads from
                            // the same target's state below.
                            self.resolve_compute_adapters(
                                &inner_result, &dispatched.command_name,
                            );
                            // i220-1 — fire the :llm hook on cascade
                            // dispatches the same way `Runtime::dispatch`
                            // fires it after top-level dispatch settles.
                            // Without this, PM-driven cascades (Dream PM
                            // dispatching Dream.RecordImage, etc.) never
                            // reach the named-adapter pipeline that wires
                            // `:dream_image` / `:dream_translate` to
                            // Claude. The recursion is bounded : the
                            // LLM hook itself uses `dispatch_cascade`
                            // (not `Runtime::dispatch`), so the response
                            // chain is one-shot per match — same shape
                            // the top-level call already relies on.
                            self.resolve_llm_adapters(
                                &inner_result, &dispatched.command_name,
                            );
                            // Process-spawn primitive on PM cascades —
                            // same hook as the policy arm below.
                            self.resolve_primitive_spawn(
                                &inner_result, &dispatched.command_name, &cascade_attrs,
                                Some(event),
                            );
                        }
                    }
                }
                self.pm_engine.complete(&t.pm_name);
            }

            let triggers = self.policy_engine.react(event);
            for trigger in triggers {
                let policy_name = trigger.policy_name.clone();
                let cmd = trigger.command_name.clone();
                let mut data = trigger.event_data.clone();
                // Gap #1 — merge the policy's `with` literals over the
                // event data (the policy's explicit args win). This is
                // how a policy firing `Primitive::Process.Spawn` carries
                // the literal `cmd` + `result_into` the retired :exec
                // resolver used to inline.
                for (k, v) in &trigger.with_data {
                    data.insert(k.clone(), v.clone());
                }

                // i622 — policy reaction log. Printed at every level
                // (including quiet) because policy chains are the
                // operational signal operators most often want to see.
                storehouse_log::policy_reaction(
                    &policy_name,
                    &event.aggregate_type,
                    &event.name,
                    &event.aggregate_id,
                    &cmd,
                );

                // Inject every reference the triggered command needs:
                //   1. self-ref or upstream-ref → use upstream event's aggregate_id
                //   2. other refs → use any record currently in that repo (singleton)
                // This makes static cascade prediction work across aggregate
                // boundaries: a policy chain can hop A→B→C even when neither
                // B nor C's input attrs were in the original test command.
                self.inject_refs(&cmd, &event.aggregate_type, &event.aggregate_id, &mut data);

                // i111-K — pass the upstream type+id as a cascade hint.
                // When the triggered command's aggregate matches
                // upstream_type AND a record exists at upstream_id, the
                // cascade preserves the id rather than counter-minting
                // a fresh one. This closes the i111-C surprise where
                // multi-step pipeline roots had to declare
                // `identified_by` just to keep gated cascades landing
                // on the same row. Cross-type cascades (A → B) and
                // cases without an existing record fall through to
                // standard resolution unchanged.
                // Clone the dispatch data BEFORE the move so the
                // process-spawn primitive hook below can read `cmd` /
                // `result_into` / `id` off the just-dispatched command's
                // attrs (the adapters-as-bluebook policy path).
                let cascade_attrs = data.clone();
                let inner = command_dispatch::dispatch_cascade(
                    self, &cmd, data,
                    &event.aggregate_type, &event.aggregate_id,
                );
                // i622 — cascade step log. Policy-driven cascade.
                storehouse_log::cascade_step(
                    &cmd, &event.aggregate_id, inner.is_ok(),
                );
                if let Ok(inner_result) = inner {
                    self.drain_policies(&inner_result);
                    // i220 sub-gap 5 — :compute hook on policy
                    // cascades. Same ordering as the PM arm above :
                    // compute first (populates fields), then LLM
                    // (reads them in the prompt template).
                    self.resolve_compute_adapters(&inner_result, &cmd);
                    // i220-1 — same cascade-LLM hook as the PM-dispatch
                    // arm above. Policy-driven cascades (react_to /
                    // policy.bluebook) need the named-adapter pipeline
                    // too. Without this, any policy chain landing on
                    // `Dream.RecordImage` (or any other adapter target)
                    // would silently skip Claude.
                    self.resolve_llm_adapters(&inner_result, &cmd);
                    // Process-spawn primitive on policy cascades. This
                    // is the path the re-expressed `:exec` adapter takes :
                    // a policy fires `Primitive::Process.Spawn`, this
                    // hook runs the literal cmd and cascades into
                    // result_into. Without it, the policy-driven spawn
                    // would dispatch the Process record but never run.
                    self.resolve_primitive_spawn(&inner_result, &cmd, &cascade_attrs, Some(event));
                }
                self.policy_engine.complete(&policy_name);
            }
        }
    }

    /// Evaluate one with-spec entry into a runtime Value at PM
    /// dispatch time. Four kinds :
    ///
    ///   - `Literal { value }`             → `Value::Str(value)`
    ///   - `FromEvent { name, default }`    → `event.data[name]` ;
    ///                                        falls back to literal
    ///                                        from `default` ;
    ///                                        returns `None` when
    ///                                        both are absent.
    ///   - `FromPm { name, default }`       → `pm.attributes[name]` ;
    ///                                        same fallback semantics.
    ///   - `FromIter { field }`             → i221-B : reads
    ///                                        `iter_data[field]` (the
    ///                                        current sweep record).
    ///                                        Returns `None` outside a
    ///                                        `for_each:` sweep.
    ///
    /// Returns `None` when no value resolves (caller skips the key
    /// so the receiving aggregate sees no entry — same as if the
    /// dispatch never named it).
    ///
    /// Phase 2.c — FromPm now reads from the PM instance's
    /// `attributes` hash (populated by handlers' `set` directives).
    /// When the attribute is absent the spec's `default` fires ;
    /// when both are absent, returns None.
    ///
    /// i221-B — `iter_data` carries the current sweep record's fields
    /// (set by `drain_policies` when a DispatchSpec has `for_each:
    /// Some(_)`). `None` for bare dispatches ; `Some(&fields)` per
    /// record during a sweep loop.
    fn evaluate_value_spec(
        &self,
        spec: &crate::ir::ValueSpec,
        event: &Event,
        pm_name: &str,
        correlation_id: &str,
        iter_data: Option<&HashMap<String, Value>>,
    ) -> Option<Value> {
        use crate::ir::ValueSpec;
        match spec {
            ValueSpec::Literal { value } => Some(Value::Str(value.clone())),
            ValueSpec::FromEvent { name, default } => {
                if let Some(v) = event.data.get(name) {
                    return Some(v.clone());
                }
                default.as_ref().map(|d| Value::Str(d.clone()))
            }
            ValueSpec::FromPm { name, default } => {
                if let Some(v) = self.pm_engine.read_attribute(pm_name, correlation_id, name) {
                    return Some(Value::Str(v.to_string()));
                }
                default.as_ref().map(|d| Value::Str(d.clone()))
            }
            // i221-B — pull the named field off the current sweep
            // record. When `iter_data` is `None` (bare dispatch), or
            // the record doesn't carry the field, returns `None` and
            // the caller leaves the key unset.
            ValueSpec::FromIter { field } => {
                iter_data.and_then(|m| m.get(field).cloned())
            }
        }
    }

    /// Phase 2.c — resolve every `set` directive on the firing
    /// handler into concrete (attr, String) pairs, ready to write to
    /// the PM instance. Reuses the same ValueSpec evaluator as the
    /// dispatch with-spec ; coerces the resolved Value to its
    /// Display form (matches the storage convention — attributes
    /// round-trip as JSON strings). Skips entries that resolve to
    /// None (no event match + no default = leave attr untouched).
    fn pm_set_pairs(&self, t: &PMTrigger, event: &Event) -> Vec<(String, String)> {
        // The set_specs live on the handler that fired ; PMTrigger
        // doesn't carry them directly (the engine drops them when it
        // returns), so re-look them up via pm_name + (event_name,
        // from_state). One handler matches per (event_type, from_state)
        // pair (Ruby builder enforces this via single-entry
        // transition).
        let binding = match self.pm_engine.bindings().find(|b| b.name == t.pm_name) {
            Some(b) => b,
            None => return Vec::new(),
        };
        let handler = match binding
            .handlers
            .iter()
            .find(|h| h.event_type == t.event_name && h.from_state == t.from_state)
        {
            Some(h) => h,
            None => return Vec::new(),
        };
        let mut out = Vec::new();
        for (attr, spec) in &handler.set_specs {
            // i221-B — set_specs run BEFORE the dispatch loop ; they
            // can't be inside a `for_each:` iteration (the iter
            // context belongs to the dispatched command, not the PM
            // attribute write). Pass `None` for iter_data so any
            // stray `from_iter(:_)` in a set spec resolves to None
            // (= no write), which is the correct fallback semantics.
            if let Some(v) = self.evaluate_value_spec(spec, event, &t.pm_name, &t.correlation_id, None) {
                out.push((attr.clone(), v.to_string()));
            }
        }
        out
    }

    /// i221-B — resolve a `for_each: { from: "Aggregate.query" }`
    /// sweep source to a list of per-record field maps. Each returned
    /// HashMap carries the record's fields keyed by attribute name ;
    /// `from_iter(:field)` in the dispatch's with-spec reads from
    /// these maps during the cascade loop.
    ///
    /// Resolution order :
    ///
    ///   1. Look up the named query in the source aggregate's IR ;
    ///      run it through `resolve_query` to apply declared wheres /
    ///      order_by / limit. Returns the structured records.
    ///   2. When the query name doesn't match a declared query (the
    ///      Synapse.cold / Signal.cold use case where the predicate
    ///      lives in the aggregate's specifications block, not its
    ///      queries), fall back to `repo.all()` so the sweep at
    ///      least enumerates every record. Future i225 work : lift
    ///      specifications into queryable predicates so the sweep is
    ///      a true filtered enumeration.
    ///
    /// An empty sweep returns an empty Vec, which the caller treats
    /// as "no records → no dispatches" — same as a `for_each` over an
    /// empty iterable.
    fn sweep_records(&self, spec: &crate::ir::ForEachSpec, attrs: &HashMap<String, String>) -> Vec<HashMap<String, Value>> {
        // First : try the structured query path. Filter by aggregate
        // name AND (when supplied) bluebook context — disambiguates
        // when the same aggregate name exists in multiple bluebooks
        // (e.g. mind/state/musing.bluebook + mind/musings/musings.bluebook
        // both declare "Musing").
        let has_query = self.domain.aggregates.iter()
            .any(|a| a.name == spec.source_aggregate
                && spec.source_context.as_ref().map_or(true, |ctx| {
                    a.context.as_ref().map_or(false, |c| c == ctx)
                })
                && a.queries.iter().any(|q| q.name == spec.query_name));

        if has_query {
            let json = self.resolve_query_qualified(
                spec.source_context.as_deref(),
                &spec.source_aggregate,
                &spec.query_name,
                attrs,
            );
            let mut out = Vec::new();
            // resolve_query returns either an object (single match)
            // or an array under .state. Normalize.
            let state = json.get("state").cloned().unwrap_or(serde_json::Value::Null);
            match state {
                serde_json::Value::Array(arr) => {
                    for item in arr {
                        if let serde_json::Value::Object(map) = item {
                            out.push(json_obj_to_value_map(map));
                        }
                    }
                }
                serde_json::Value::Object(map) => {
                    out.push(json_obj_to_value_map(map));
                }
                _ => {}
            }
            return out;
        }

        // Fallback : enumerate all records of the source aggregate.
        // The aggregate-level specification (e.g. Synapse :cold) isn't
        // a first-class query yet ; sweeping `repo.all()` and letting
        // the receiving command's givens gate is the transitional
        // semantics. Receiving aggregates with `given` clauses will
        // short-circuit on records that don't qualify.
        self.all(&spec.source_aggregate)
            .iter()
            .map(|s| s.fields.clone())
            .collect()
    }

    /// For each reference on the triggered command, inject an id under its
    /// kwarg name if not already present:
    ///   - target matches upstream event's aggregate type → use event's id
    ///   - target is the command's own aggregate (self-ref) and a record
    ///     exists in that repo → use the existing record's id
    ///   - target is any other aggregate with an existing record (singleton
    ///     pattern) → use that record's id
    /// The bluebook stays reference-only; the runtime resolves to ids.
    fn inject_refs(
        &self,
        cmd_name: &str,
        upstream_type: &str,
        upstream_id: &str,
        data: &mut HashMap<String, Value>,
    ) {
        for agg in &self.domain.aggregates {
            for cmd in &agg.commands {
                if cmd.name != cmd_name { continue; }
                for r in &cmd.references {
                    if data.contains_key(&r.name) { continue; }
                    if r.target == upstream_type {
                        data.insert(r.name.clone(), Value::Str(upstream_id.to_string()));
                        continue;
                    }
                    // Singleton fallback: pick any existing record of the
                    // ref's target type. References don't carry context ;
                    // resolve target's context by scanning the loaded
                    // domain (i142 Tier 2). True cross-context refs land
                    // in Tier 3.
                    //
                    // i161 — when the same aggregate name lives in
                    // multiple contexts (e.g. Mind.Musing + Musings.Musing
                    // post-i117 R4), the naive `find()` returns the first
                    // by depth-then-path iteration order, so the wrong
                    // context wins and singleton fallback hits the wrong
                    // repo. The dispatching command is on `agg` ; prefer
                    // a target in the SAME context, fall back to first
                    // match for genuine cross-context refs. Self-refs
                    // (r.target == agg.name) resolve trivially via
                    // agg.context — no domain scan needed.
                    let target_ctx = if r.target == agg.name {
                        agg.context.as_deref()
                    } else {
                        self.domain.aggregates.iter()
                            .find(|a| a.name == r.target && a.context == agg.context)
                            .or_else(|| self.domain.aggregates.iter().find(|a| a.name == r.target))
                            .and_then(|a| a.context.as_deref())
                    };
                    let key = repo_key(target_ctx, &r.target);
                    if let Some(repo) = self.repositories.get(&key) {
                        if let Some(existing) = repo.all().first() {
                            data.insert(r.name.clone(), Value::Str(existing.id.clone()));
                        }
                    }
                }
                // Inject the identity field when the triggered command's
                // aggregate uses identified_by. Two cases this catches:
                //   1. Key absent — policy cascade didn't supply an id.
                //   2. Key present but value doesn't match any record —
                //      upstream aggregate leaked its own identified_by field
                //      (e.g. Pulse's `name="pulse"` in a BodyPulse event) into
                //      the cascade data, pointing at a non-existent record.
                // The injection picks the lexicographically lowest existing
                // record id (deterministic). For natural-key singletons
                // (Heartbeat → "heartbeat", Tick → "tick"), this finds the
                // canonical row even when junk counter-minted records sit
                // alongside it. Without this, every cascade tick creates yet
                // another counter-minted record because id_for_command
                // honored the leaked upstream value.
                if let Some(ref key) = agg.identified_by {
                    let agg_key = repo_key(agg.context.as_deref(), &agg.name);
                    if let Some(repo) = self.repositories.get(&agg_key) {
                        let needs_inject = match data.get(key.as_str()) {
                            None => true,
                            Some(v) => v.as_str()
                                .map(|s| repo.find(s).is_none())
                                .unwrap_or(true),
                        };
                        if needs_inject {
                            // Prefer a record whose id is non-numeric (the
                            // natural-key form, e.g. "heartbeat") over a
                            // counter-minted u64 id ("1", "42", "302" — the
                            // junk left by pre-i80 dispatches). Within each
                            // group fall back to lex-min for determinism.
                            let pick = repo.all().iter()
                                .map(|s| s.id.clone())
                                .min_by(|a, b| {
                                    let an = a.chars().all(|c| c.is_ascii_digit());
                                    let bn = b.chars().all(|c| c.is_ascii_digit());
                                    an.cmp(&bn).then_with(|| a.cmp(b))
                                });
                            if let Some(id) = pick {
                                data.insert(key.clone(), Value::Str(id));
                            } else {
                                // Empty repo + leaked upstream key (i151) —
                                // remove the leaked id so id_for_command
                                // counter-mints a fresh id rather than
                                // creating a record named after the upstream
                                // aggregate (e.g. heartbeat with id="tick"
                                // because Tick.MindstreamTick's name="tick"
                                // leaked through Ticked → Pulse.Emit →
                                // BodyPulse → AccumulateFatigue). Without
                                // this, every singleton aggregate downstream
                                // of a named-key emitter inherits the wrong
                                // identifier on first dispatch and silently
                                // accumulates orphans in subsequent ticks.
                                data.remove(key.as_str());
                            }
                        }
                    }
                }
                return; // first matching command wins
            }
        }
    }

    pub fn add_projection(&mut self, projection: Projection) {
        self.projections.push(projection);
    }

    pub fn query_projection(
        &self,
        projection_name: &str,
        query_name: &str,
    ) -> Vec<HashMap<String, Value>> {
        for proj in &self.projections {
            if proj.name == projection_name {
                return proj.query(query_name);
            }
        }
        vec![]
    }
    /// Resolve a query — search IR or return aggregate state.
    ///
    /// i101 — when the IR Query carries structured wheres / order_by /
    /// limit, the executor walks repo.all() and applies them in order :
    /// filter → sort → truncate. The opaque-Ruby-block era is retired.
    ///
    /// Back-compat unqualified entry point. Delegates to
    /// `resolve_query_qualified` with `(None, "")` so callers that only
    /// know the query name still work. Sweep dispatches (i221-A) reach
    /// for the qualified form so same-named queries across bluebooks
    /// can be disambiguated.
    pub fn resolve_query(&self, query_name: &str, attrs: &std::collections::HashMap<String, String>) -> serde_json::Value {
        self.resolve_query_qualified(None, "", query_name, attrs)
    }

    /// Run interactively — the terminal adapter drives the runtime.
    #[cfg(not(target_arch = "wasm32"))]
    pub fn run_interactive(&mut self) {
        let name = self.domain.name.clone();
        adapter_terminal::run(self, &name);
    }
}

/// Dynamic value — aggregates are bags of these
#[derive(Debug, Clone, PartialEq)]
pub enum Value {
    Str(String),
    Int(i64),
    Bool(bool),
    List(Vec<Value>),
    Map(HashMap<String, Value>),
    Null,
}

/// i697 — serialise dispatch attrs to a compact JSON object string for
/// the rich dispatch-detail block's `args` field. String/Int/Bool map
/// cleanly ; lists/maps/null fall back to their Display form as a string.
fn dispatch_detail_args_json(attrs: &HashMap<String, Value>) -> String {
    let mut map = serde_json::Map::new();
    for (k, v) in attrs {
        map.insert(k.clone(), value_to_json(v));
    }
    serde_json::Value::Object(map).to_string()
}

/// i697 — serialise an aggregate's final state to a compact JSON object
/// string for the rich block's `result_state` field.
fn dispatch_detail_state_json(state: &AggregateState) -> String {
    let mut map = serde_json::Map::new();
    for (k, v) in &state.fields {
        map.insert(k.clone(), value_to_json(v));
    }
    serde_json::Value::Object(map).to_string()
}

/// Map a runtime `Value` into a serde_json value for the rich block.
/// C2 (transactional outbox) — decode a CascadeRun Step's JSON payload
/// back into a dispatch attr map, so the pump can re-dispatch the reaction
/// with the triggering event's data. Inverse of the value_to_json encode in
/// record_cascade_run. Non-object / malformed payloads yield empty attrs.
fn parse_payload_attrs(json: &str) -> HashMap<String, Value> {
    let mut out = HashMap::new();
    if let Ok(serde_json::Value::Object(obj)) = serde_json::from_str::<serde_json::Value>(json) {
        for (k, v) in obj {
            let val = match v {
                serde_json::Value::String(s) => Value::Str(s),
                serde_json::Value::Bool(b) => Value::Bool(b),
                serde_json::Value::Number(n) => n.as_i64().map(Value::Int).unwrap_or(Value::Null),
                serde_json::Value::Null => Value::Null,
                other => Value::Str(other.to_string()),
            };
            out.insert(k, val);
        }
    }
    out
}

pub(crate) fn value_to_json(v: &Value) -> serde_json::Value {
    match v {
        Value::Str(s) => serde_json::json!(s),
        Value::Int(n) => serde_json::json!(n),
        Value::Bool(b) => serde_json::json!(b),
        Value::List(items) => serde_json::Value::Array(items.iter().map(value_to_json).collect()),
        Value::Map(m) => {
            let mut o = serde_json::Map::new();
            for (k, val) in m {
                o.insert(k.clone(), value_to_json(val));
            }
            serde_json::Value::Object(o)
        }
        Value::Null => serde_json::Value::Null,
    }
}

/// Inverse of value_to_json : decode a serde_json value back into a runtime
/// `Value`, RECURSIVELY (nested objects -> Value::Map, arrays -> Value::List).
/// Used by unconsolidated_log_tail to rebuild each shard Event's nested shape
/// (delta{field,value}, sequence{value}) so the fold reads tail records exactly
/// as it reads consolidated ones. A whole-number JSON number decodes to Int ;
/// any other number (float) falls back to its string form, matching the heki
/// reader's own from_json.
fn json_to_value_recursive(v: &serde_json::Value) -> Value {
    match v {
        serde_json::Value::String(s) => Value::Str(s.clone()),
        serde_json::Value::Bool(b) => Value::Bool(*b),
        serde_json::Value::Number(n) => match n.as_i64() {
            Some(i) => Value::Int(i),
            None => Value::Str(n.to_string()),
        },
        serde_json::Value::Null => Value::Null,
        serde_json::Value::Array(a) => {
            Value::List(a.iter().map(json_to_value_recursive).collect())
        }
        serde_json::Value::Object(m) => {
            Value::Map(m.iter().map(|(k, v)| (k.clone(), json_to_value_recursive(v))).collect())
        }
    }
}

/// The set of live process ids, via one `ps -A -o pid=` probe. Returns None
/// when liveness cannot be TRUSTED (ps failed, or returned an implausibly
/// empty set), so the caller reclaims NOTHING this pass rather than risk
/// deleting a live process's open shard (whose unlinked inode would swallow
/// its future appends). Dependency-free — no libc — : one cheap subprocess per
/// consolidation tick, far cheaper than a kill(2) per shard.
fn live_pids() -> Option<std::collections::HashSet<u32>> {
    let out = std::process::Command::new("ps")
        .args(["-A", "-o", "pid="])
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let set: std::collections::HashSet<u32> = String::from_utf8_lossy(&out.stdout)
        .lines()
        .filter_map(|l| l.trim().parse::<u32>().ok())
        .collect();
    if set.is_empty() {
        None // implausible : treat as failure, reclaim nothing
    } else {
        Some(set)
    }
}

impl Value {
    pub fn as_str(&self) -> Option<&str> {
        match self {
            Value::Str(s) => Some(s),
            _ => None,
        }
    }

    pub fn as_int(&self) -> Option<i64> {
        match self {
            Value::Int(n) => Some(*n),
            _ => None,
        }
    }

    pub fn as_bool(&self) -> Option<bool> {
        match self {
            Value::Bool(b) => Some(*b),
            _ => None,
        }
    }

    pub fn as_list(&self) -> Option<&Vec<Value>> {
        match self {
            Value::List(v) => Some(v),
            _ => None,
        }
    }
}

impl std::fmt::Display for Value {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Value::Str(s) => write!(f, "{}", s),
            Value::Int(n) => write!(f, "{}", n),
            Value::Bool(b) => write!(f, "{}", b),
            Value::List(v) => write!(f, "[{} items]", v.len()),
            Value::Map(m) => write!(f, "{{{} fields}}", m.len()),
            Value::Null => write!(f, "null"),
        }
    }
}

#[derive(Debug)]
pub enum RuntimeError {
    UnknownCommand(String),
    UnknownAggregate(String),
    /// i735 defect 2 — a dispatch targeted an aggregate whose wired
    /// `:sqlite` adapter failed to build at boot (the table could not be
    /// created / the db could not be opened). The runtime refused that
    /// aggregate's persistence rather than panicking or silently swapping
    /// to heki ; the message carries the loud reason recorded at boot.
    PersistenceRefused(String),
    GivenFailed { message: String, expression: String },
    /// f4 — an aggregate-level invariant's `holds_when` predicate was false
    /// on the resulting state after a command's mutations. The command is
    /// rejected with 0 events, the same shape as a failed `given`. `name`
    /// is the invariant's rule name ; `expression` is its predicate source.
    InvariantViolation { name: String, expression: String },
    AggregateNotFound(String),
    MissingAttribute(String),
    LifecycleViolation {
        command: String,
        field: String,
        current: String,
        allowed: Vec<String>,
    },
    /// i156 — bare-name dispatch resolved to multiple aggregates when
    /// `HECKS_STRICT_DISPATCH=1` is set. The validator_corpus
    /// `bare_name_collisions` rule flags these statically ; this is
    /// the runtime-side enforcement for callers that haven't
    /// migrated.
    AmbiguousCommand {
        name: String,
        candidates: Vec<String>,
    },
}

impl std::fmt::Display for RuntimeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            RuntimeError::UnknownCommand(c) => write!(f, "unknown command: {}", c),
            RuntimeError::UnknownAggregate(a) => write!(f, "unknown aggregate: {}", a),
            RuntimeError::PersistenceRefused(m) => write!(f, "{}", m),
            RuntimeError::GivenFailed { message, .. } => write!(f, "given failed: {}", message),
            RuntimeError::InvariantViolation { name, .. } => write!(f, "invariant violation: {}", name),
            RuntimeError::AggregateNotFound(id) => write!(f, "aggregate not found: {}", id),
            RuntimeError::MissingAttribute(a) => write!(f, "missing attribute: {}", a),
            RuntimeError::LifecycleViolation { command, field, current, allowed } => {
                write!(f, "lifecycle violation: {} cannot run when {} is '{}' (allowed from: {:?})",
                    command, field, current, allowed)
            }
            RuntimeError::AmbiguousCommand { name, candidates } => {
                write!(f, "ambiguous bare-name dispatch: '{}' is declared on aggregates {:?} — qualify with `Aggregate.{}`",
                    name, candidates, name)
            }
        }
    }
}

/// Macro for building attribute maps
#[macro_export]
macro_rules! attrs {
    ($($key:expr => $val:expr),* $(,)?) => {{
        let mut map = std::collections::HashMap::new();
        $(map.insert($key.to_string(), $val);)*
        map
    }};
}

/// i142 Tier 2 — compose the HashMap key for a repository.
/// Same-name aggregates in different bounded contexts get distinct
/// keys ("Library::Inbox" vs "Workshop::Inbox") so they end up with
/// distinct Repository instances and distinct .heki paths.
/// Legacy aggregates without a context use their bare name.
pub fn repo_key(context: Option<&str>, name: &str) -> String {
    match context {
        Some(ctx) => format!("{}::{}", ctx, name),
        None => name.to_string(),
    }
}

/// i142 Tier 2 — name-only lookup helper for callers that don't yet
/// carry context info (public Runtime::find/all, behaviors runners,
/// CommandResult-driven main loops). Scans for an exact match first
/// (legacy / context-less repository), then for any "<ctx>::<name>"
/// key. With name uniqueness inside the loaded domain (the common
/// case), this is unambiguous. True same-name collisions across
/// contexts surface as nondeterministic picks here — those callers
/// should be migrated to keyed lookup as Tier 3 progresses.
pub fn repo_lookup_key(repositories: &HashMap<String, LazyRepository>, name: &str) -> Option<String> {
    if repositories.contains_key(name) {
        return Some(name.to_string());
    }
    let suffix = format!("::{}", name);
    repositories.keys().find(|k| k.ends_with(&suffix)).cloned()
}

/// i101 — apply one WhereClause to one record. Resolves kwarg-refs
/// (`":author"`) against the dispatch attrs ; literal values match
/// the record's field as a string. Returns true when the record
/// matches the clause, false otherwise.
fn where_matches(
    state: &AggregateState,
    clause: &crate::ir::WhereClause,
    attrs: &std::collections::HashMap<String, String>,
) -> bool {
    let target = resolve_where_value(&clause.value, attrs);
    let actual = resolve_state_field(state, &clause.field);
    match clause.op {
        crate::ir::WhereOp::Eq  => actual == target,
        crate::ir::WhereOp::Ne  => actual != target,
        crate::ir::WhereOp::Gt  => compare_strings(&actual, &target).is_gt(),
        crate::ir::WhereOp::Gte => !compare_strings(&actual, &target).is_lt(),
        crate::ir::WhereOp::Lt  => compare_strings(&actual, &target).is_lt(),
        crate::ir::WhereOp::Lte => !compare_strings(&actual, &target).is_gt(),
        crate::ir::WhereOp::In  => target.split(',').any(|item| item.trim() == actual),
        // Resolved is a cross-aggregate op resolved upstream in
        // resolve_query_qualified (needs &Runtime) ; never reached here.
            // Contains : a record LOCAL list field contains the literal value.
            // Aggregate-local (reads the record own list) — Story.DependentsOf : every
            // story whose dependencies list contains the given dep ref.
            crate::ir::WhereOp::Contains => match state.fields.get(&clause.field) {
                Some(Value::List(items)) => items.iter().any(|v| v.to_string() == target),
                Some(Value::Str(csv)) => csv.split(',').any(|x| x.trim() == target),
                _ => false,
            },
        // NoneInState is a cross-aggregate anti-join resolved upstream in
        // resolve_query_qualified (needs &Runtime) ; never reached here.
        crate::ir::WhereOp::NoneInState => true,
    }
}

/// Numeric ordering when both sides parse as i64 ; lexical otherwise.
/// Keeps the runtime executor honest for both string-typed status
/// fields and numeric-typed counters.
fn compare_strings(a: &str, b: &str) -> std::cmp::Ordering {
    if let (Ok(an), Ok(bn)) = (a.parse::<i64>(), b.parse::<i64>()) {
        return an.cmp(&bn);
    }
    a.cmp(b)
}

/// Resolve a clause field to its string value, walking a DOTTED path
/// (`sequence.value`) through nested `Value::Map`s. A bare field reads the
/// top-level value as before (a `Value::Map` Displays as `"{N fields}"`, so a
/// bare `sequence` still never matches a number — which is exactly why an
/// Event-Log sequence predicate must use `sequence.value`). Missing field or a
/// non-map mid-path yields "" (the oracle's `unwrap_or_default` parity).
fn resolve_state_field(state: &AggregateState, field: &str) -> String {
    let mut parts = field.split('.');
    let head = match parts.next() {
        Some(h) => h,
        None => return String::new(),
    };
    let mut cur = match state.fields.get(head) {
        Some(v) => v,
        None => return String::new(),
    };
    for key in parts {
        match cur {
            Value::Map(m) => match m.get(key) {
                Some(v) => cur = v,
                None => return String::new(),
            },
            _ => return String::new(),
        }
    }
    // Single-value VO unwrap : a VO with exactly one `value` field IS its
    // value, so a bare-VO field (e.g. `sequence` -> {"value": N}) compares by
    // the inner value, not the map's Display ("{1 fields}"). This mirrors how
    // the in-memory behaviors runtime treats a VO, closing the storehouse-side
    // gap that left Event.AtSequence (bare `sequence` Eq) silently unmatched.
    match cur {
        Value::Map(m) if m.len() == 1 => {
            m.get("value").map(|v| v.to_string()).unwrap_or_else(|| cur.to_string())
        }
        _ => cur.to_string(),
    }
}

/// Resolve a where-clause value : `:foo` reads `attrs["foo"]` (kwarg-ref) ;
/// any other token is a literal returned as-is.
fn resolve_where_value(
    value: &str,
    attrs: &std::collections::HashMap<String, String>,
) -> String {
    if let Some(kwarg) = value.strip_prefix(':') {
        return attrs.get(kwarg).cloned().unwrap_or_default();
    }
    value.to_string()
}

/// Resolve a limit value : `:foo` reads `attrs["foo"]` and parses as
/// usize ; numeric token parses directly. Returns None when the source
/// can't be parsed (so the executor leaves the result un-truncated).
fn resolve_limit_value(
    value: &str,
    attrs: &std::collections::HashMap<String, String>,
) -> Option<usize> {
    if let Some(kwarg) = value.strip_prefix(':') {
        return attrs.get(kwarg).and_then(|s| s.parse::<usize>().ok());
    }
    value.parse::<usize>().ok()
}

fn pascal_to_phrase(name: &str) -> String {
    let mut result = String::new();
    for (i, c) in name.chars().enumerate() {
        if i > 0 && c.is_uppercase() { result.push(' '); }
        result.push(c.to_lowercase().next().unwrap_or(c));
    }
    result
}

fn trigram_sim(a: &str, b: &str) -> f64 {
    if a == b { return 1.0; }
    let a_t: Vec<String> = a.chars().collect::<Vec<_>>().windows(3).map(|w| w.iter().collect()).collect();
    let b_t: Vec<String> = b.chars().collect::<Vec<_>>().windows(3).map(|w| w.iter().collect()).collect();
    if a_t.is_empty() || b_t.is_empty() { return 0.0; }
    let matches = a_t.iter().filter(|t| b_t.contains(t)).count();
    (2.0 * matches as f64) / (a_t.len() + b_t.len()) as f64
}

/// i551 — strip the surrounding shape a hecksagon-options value
/// carries from `parse_options`. String literals come through as
/// `"\"Tools.Bash\""` (raw source token, quotes included) ; symbols
/// come through as `":bash"` (leading colon kept). Both forms need
/// to be reduced to their bare identifier before matching against
/// runtime targets / dispatcher tool names. Whitespace is trimmed
/// because parse_options preserves it from the source.
pub(crate) fn strip_quotes_or_colon(raw: &str) -> String {
    let t = raw.trim();
    if t.len() >= 2 && t.starts_with('"') && t.ends_with('"') {
        return t[1..t.len() - 1].to_string();
    }
    if let Some(rest) = t.strip_prefix(':') {
        return rest.to_string();
    }
    t.to_string()
}

/// i221-B — convert a serde_json::Map into a HashMap<String, Value>
/// for use as `iter_data` in a sweep dispatch. The sweep records come
/// from `resolve_query` which serializes through serde_json ; this
/// brings them back into the runtime's Value enum so `from_iter
/// (:field)` reads land in the right shape.
fn json_obj_to_value_map(map: serde_json::Map<String, serde_json::Value>) -> HashMap<String, Value> {
    let mut out = HashMap::new();
    for (k, v) in map {
        let value = match v {
            serde_json::Value::String(s) => Value::Str(s),
            serde_json::Value::Bool(b)   => Value::Bool(b),
            serde_json::Value::Number(n) => {
                if let Some(i) = n.as_i64() { Value::Int(i) } else { Value::Str(n.to_string()) }
            }
            serde_json::Value::Null      => Value::Null,
            other                        => Value::Str(other.to_string()),
        };
        out.insert(k, value);
    }
    out
}
