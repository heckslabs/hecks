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
pub mod acl_readmodel;
pub(crate) mod command_dispatch;
pub mod payload_gate;
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
// The persistence-resolution `impl Runtime` methods (dump_backend_map,
// unwired_aggregates) live in this hand-written child module, not in mod.rs.
// Inherent impl in a child module attaches to Runtime. (Was a runtime_shape
// codegen artifact until 2026-06-27.)
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
/// Framework substrate — the collaborator holding the kernel's own aggregates
/// (the event Log, the veto audit, the outbox), so the runtime never depends on
/// a user's domain having merged them.
mod framework_substrate;
/// Event sourcing — per-delta Event append, causation lineage, consolidation.
/// (Distinct from `crate::event_log`, the storage primitive it writes through.)
mod event_sourcing;
// value_convert — Value<->JSON conversion + coercion cask (shrink-mod phase B
// wave 1). Re-exported at the SAME paths the fns always had, so no caller
// changes : the pub trio stays `runtime::value_to_json_string` etc., the
// crate-internal value_to_json stays `pub(crate)`, and the private helpers
// stay reachable by mod.rs + child modules through this use.
mod value_convert;
pub use value_convert::{attr_value_from_str, value_from_json_str, value_to_json_string};
// errors — RuntimeError + its Display (shrink-mod phase B cask). Same path :
// `runtime::RuntimeError` resolves through this re-export unchanged.
// boot / boot_persistent — the constructor casks (shrink-mod phase B).
mod auth_gates;
mod authz;
mod boot;
mod boot_persistent;
mod cascade_record;
mod effect_outbound;
mod errors;
mod primitive_spawn;
mod policy_eval;
pub use errors::RuntimeError;
use errors::PolicyOutcome;
pub(crate) use value_convert::value_to_json;
use value_convert::{json_obj_to_value_map, json_to_value_recursive, parse_payload_attrs};
// i-lazy — boot-map lazy hydration. Wraps Repository in a OnceCell so
// boot constructs all 458 repos WITHOUT touching disk ; each repo's
// load_persisted runs on first access. Kills the ~4.2s eager-hydration
// tax on a single-shot dispatch (which touches exactly one repo).
mod lazy_repository;
// The persistence PORT (hexagon) — wired backends implement this trait and the
// kernel holds them as `Box<dyn PersistenceAdapter>`, naming no concrete engine.
pub mod persistence_adapter;
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
// The pure 5-field cron-expression matcher — sibling of drive_scheduler for
// the CRON kind. `storehouse drive` asks `is_due(expr, now)` to fire
// `driving on cron` handlers only on a matching minute.
pub mod cron_schedule;
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
// SQL pushdown (sql_query / sqlite_query) + its parity tests live in the
// storehouse-sqlite crate now — the persistence adapter owns its query surface
// and its rusqlite dependency. The lib names no engine.
// Phase 4 of the where() overhaul — the CausationTrace lineage traversal
// (resolve_query_qualified's recursive branch), tested over a seeded chain.
#[cfg(all(test, not(target_arch = "wasm32")))]
mod causation_trace_tests;
// The FORWARD half — ConsequenceTree fans out over the reverse index
// (causation_id -> children), tested over seeded trees a live cascade can't shape.
#[cfg(all(test, not(target_arch = "wasm32")))]
mod consequence_tree_tests;
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
#[cfg(not(target_arch = "wasm32"))]
pub(crate) use command_dispatch::apply_lifecycle_default;
pub use event_bus::{Event, EventBus};
pub use middleware::{MiddlewareEntry, MiddlewareStack, Phase};
pub use policy_engine::{PolicyEngine, PolicyTrigger};
pub use pm_engine::{PMBinding, PMEngine, PMInstanceState, PMTrigger};
pub use projection::Projection;
pub use repository::Repository;
pub use lazy_repository::{BackendKind, LazyRepository};
pub use persistence_adapter::{
    persistence_adapter_factory, register_persistence_adapter, AdapterFactory, PersistenceAdapter,
    PersistenceSpec,
};

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
    /// The FRAMEWORK COLLABORATOR (CARD-framework-substrate-service, step
    /// zero) — a second runtime booted on crate-owned framework substrate,
    /// which the kernel dispatches into instead of requiring that substrate to
    /// have been merged into the USER's domain.
    ///
    /// The runtime needs to write framework aggregates it does not own
    /// (`EventSourcing::Event`, `Governance::Violation`, `OutboundEvent`). It
    /// used to ask "is that aggregate in MY domain?" and silently do nothing
    /// when it wasn't — a minimal boot wrote no Log and lost authorization
    /// audit rows — while `ensure_outbox_substrate` grafted the outbox into
    /// every domain with an effect port to paper over the third. All of that
    /// is gone : the kernel calls the collaborator, which always has them.
    ///
    /// `CascadeRun` deliberately did NOT move. Its guard selects between two
    /// WORKING paths (the persistent outbox vs the in-memory pump), not
    /// between working and losing data — see CARD-framework-substrate-service.
    ///
    /// `None` until first use : booting the framework domain inside
    /// every Runtime would tax all 125 test binaries for a path most never
    /// take. `framework_mut()` boots it on demand. The collaborator's OWN
    /// `framework` stays `None`, which is what stops the recursion.
    pub framework: Option<Box<Runtime>>,
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
    #[cfg(not(target_arch = "wasm32"))]
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
    #[cfg(not(target_arch = "wasm32"))]
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
    /// Layer-2 authorization (RBAC) read-model. Boot-hydrated; refreshed when a
    /// Role/Agent lifecycle command applies. Read SYNCHRONOUSLY by authorize_check ;
    /// never bus-queried (no async, no reentrancy).
    pub acl_read_model: acl_readmodel::AclReadModel,
    /// Governability : the authorization verdict of the CURRENT top-level dispatch,
    /// captured by `authorize_entry` before it strips the principal attrs. The
    /// synchronous Log writer takes it once (`record_event_append`) to stamp the
    /// REAL actor + verdict on a recorded success, so the Log answers "who did what,
    /// under which policy." Transient, per-dispatch : set at the gate, consumed by
    /// the root write, None for cascades (which record the honest `system` actor).
    pub current_auth: Option<event_sourcing::CapturedAuth>,
    /// Per-flow correlation : one id minted at the ROOT of a dispatch and shared
    /// by every event the flow records — the root command PLUS every cascade it
    /// triggers — so the Log's ByCorrelation facet gathers a whole business flow
    /// (e.g. a transfer saga) as one unit, replacing the per-event
    /// `{type}::{id}::{event}` form. Set by dispatch_inner at the root (cascade_hint
    /// None) ; cascades inherit it ; re-minted at each new root so flows never
    /// bleed together. Transient, per-flow (the framework collaborator carries its
    /// own, never this one — framework_mut is a separate Runtime).
    pub current_correlation: Option<String>,
    /// TRUST (Stage 5) — the head of THIS process's Log hash chain : the
    /// entry_hash of the last entry it appended. Each new entry hashes its content
    /// together with this, so the entries of one shard form a chain that cannot be
    /// edited, dropped or reordered without every later entry failing to
    /// re-derive. Per-process because a shard has exactly one writer ; the merge
    /// orders shards, it does not re-chain them. None until this process writes
    /// its first entry, which is where a chain walk starts.
    pub chain_head: Option<String>,
    /// COMPLETENESS — event-rows the dispatch path knows are OWED, counted at the
    /// caller, BEFORE the writer runs.
    ///
    /// Deliberately not counted inside `record_event_append` : a writer cannot be
    /// its own oracle. The empty-delta guard that silently swallowed event-rows
    /// was an early `return` — any counter it skipped past would have been just as
    /// silent. Counting the debt OUTSIDE means every path that fails to write,
    /// including one that returns before doing anything, leaves a visible gap.
    pub event_rows_owed: u64,
    /// Event-rows the writer actually appended. `owed - written` is the number of
    /// emitted domain events the Log does not contain — which should always be 0.
    pub event_rows_written: u64,
}

impl Runtime {
    /// The reference fields (name, id) an event carries in its data — the
    /// `belongs_to` / `reference_to` leaves of the emitting aggregate, so the
    /// served causation-tree node can show WHO/WHAT the event linked (member
    /// #1, tool #1). Empty when the aggregate is unknown or has no references.
    pub fn event_refs(&self, aggregate_type: &str, data: &HashMap<String, Value>) -> Vec<(String, String)> {
        self.domain.aggregates.iter()
            .find(|a| a.name == aggregate_type)
            .map(|a| a.references.iter().filter_map(|r| {
                data.get(&r.name)
                    .map(Self::value_field)
                    .filter(|s| !s.is_empty())
                    .map(|s| (r.name.clone(), s))
            }).collect())
            .unwrap_or_default()
    }

    pub fn dispatch(
        &mut self,
        command_name: &str,
        mut attrs: HashMap<String, Value>,
    ) -> Result<CommandResult, RuntimeError> {
        // RBAC authorization gates the ENTRY dispatch (not cascades, which
        // use dispatch_cascade). Records a denial as a governed Violation
        // and strips the reserved principal attrs on success. The cold
        // one-shot CLI path (dispatch_deferred) calls authorize_entry too.
        self.authorize_entry(command_name, &mut attrs)?;
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
        // Refresh the RBAC read-model when a RoleAssignment lifecycle command
        // applied — keyed off the RESOLVED aggregate type, so it fires for
        // bare- and qualified-name dispatch alike (a bare "Assign" carries no
        // FQN prefix). An Assign/Retire is reflected on the next gate. NOTE :
        // this sees ENTRY dispatches only — cascade-authored assignments (the
        // boot roster) are covered by the post-settle `rehydrate_acl` in
        // run_boot/complete.rs and by boot-time hydration in boot_with_*.
        if r.aggregate_type == "RoleAssignment" {
            let m = acl_readmodel::AclReadModel::hydrate(self);
            self.acl_read_model = m;
        }
        // Re-hydrate the middleware stack when a Gate lifecycle command
        // applied — a Declare/Retire is reflected on the next dispatch's
        // gates, so the door is driven by the live Gate registry.
        if r.aggregate_type == "Gate" {
            self.hydrate_middleware();
        }
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

    pub(crate) fn dispatch_impl(
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
        // The log surfaces show the canonical FQN of WHERE the dispatch
            // landed — the full Realm::…::Domain::Aggregate.verb rebuilt from
            // the resolved aggregate's stamped realm_path — not the terse
            // 2-seg the caller typed. `storehouse follow` is realm-explicit,
            // and a mis-resolve is visible instead of hiding behind the short
            // form. Falls back to the raw name when it can't resolve.
            let log_name = command_dispatch::canonical_for_log(self, command_name);
            let args_json = dispatch_detail_args_json(&attrs);
            let mut detail_scope =
                dispatch_detail::DispatchScope::begin(&invocation_id, &log_name, args_json);

            storehouse_log::dispatch_entry(&log_name, &invocation_id, None);

        // i622 verbose — per-attribute trace. One line per attr the
        // caller passed. Gated to the Verbose level inside the logger.
        for (k, v) in &attrs {
            storehouse_log::attribute_trace(
                    &log_name, &invocation_id, k, &v.to_string()
                );
        }

        // Snapshot the command attrs before they move into the dispatch — the
        // deferred react paths (react_ports / outbox) read them after the move.
        let ctx_attrs = attrs.clone();
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
            self.react_ports(&result, command_name, &ctx_attrs);
        } else {
            // No persistent outbox (CascadeRun not loaded) or nothing to react
            // to — fall back to the in-memory deferred path: enqueue for pump(),
            // which runs the full react() later. Held until pump, never dropped.
            self.outbox.push_back(PendingReaction {
                result: result.clone(),
                command_name: command_name.to_string(),
                attrs: ctx_attrs.clone(),
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
    /// This is the keystone the serve/dispatch boundary calls UNCONDITIONALLY
    /// (slice 2) so a synchronous caller gets the effect's result back ; it is a
    /// safe no-op when no actionable OutboundEvent exists. The shape-derived
    /// switch (`has_effect_binding_for`) decides OOP-vs-in-process per family.
    /// The CORE never blocks : it has already returned by the time this
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
    // Host-only — execs out-of-process handler binaries via run_host (wasm-gated).
    // The CF Worker has no process host ; the wasm32 sibling below is a no-op.
    #[cfg(not(target_arch = "wasm32"))]
    pub fn drain_outbound_to_quiescence(&mut self) -> usize {
        const MAX_ITERS: usize = 256;
        // The outbox lives in the framework collaborator — always available, so
        // no presence guard.
        let root = self.aggregates_root.clone().unwrap_or_default();

        struct Pending {
            delivery_id: String,
            adapter: String,
            // The ORIGIN aggregate id (OrderPlaced's Order#N). Threaded into
            // the verdict command as its self-reference `id` so an effect
            // verdict (Authorize/Decline) re-enters ON THE SAME aggregate that
            // emitted the trigger — mirrors run_host_pass. Without it, a
            // transition verdict (upsert-on-identity) mints a phantom.
            source_id: String,
            payload: String,
            success_command: String,
            failure_command: String,
        }
        fn fld(r: &serde_json::Value, k: &str) -> String {
            r[k].as_str().unwrap_or("").to_string()
        }

        let mut drained = 0usize;
        let mut iters = 0usize;
        loop {
            iters += 1;
            if iters > MAX_ITERS {
                eprintln!("[drain_outbound_to_quiescence] budget reached — stopping");
                break;
            }
            // Snapshot pending VERDICT-BEARING deliveries with a built
            // handler. WHICH deliveries are undelivered comes from the
            // declared `AllPending` query (the aggregate owns its own
            // lifecycle vocabulary) ; the verdict-bearing narrowing stays
            // here because it is a DRAIN concern, not a lifecycle one —
            // this loop only drives edges that re-enter with a verdict.
            let pending_result =
                self.framework_mut().resolve_query("AllPending", &std::collections::HashMap::new());
            let pending: Vec<Pending> = pending_result["state"]
                .as_array()
                .map(|rows| {
                    rows.iter()
                        .filter(|r| !fld(r, "success_command").is_empty())
                        .map(|r| Pending {
                            delivery_id: fld(r, "delivery_id"),
                            adapter: fld(r, "adapter"),
                            source_id: fld(r, "source_id"),
                            payload: fld(r, "payload"),
                            success_command: fld(r, "success_command"),
                            failure_command: fld(r, "failure_command"),
                        })
                        .collect()
                })
                .unwrap_or_default();

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
                    let abs = resolve_handler_path(&root, &handler);
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
                if self.framework_mut().dispatch_impl("Claim", claim).is_err() {
                    continue;
                }
                drained += 1;

                // Resolve handler + fold the .world config onto the canonical env.
                let (handler, family) = self.adapter_handler(&d.adapter).unwrap_or_default();
                let handler_path = resolve_handler_path(&root, &handler);
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
                        let _ = self.framework_mut().dispatch_impl("MarkFailed", mf);
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
                            // Async-boundary verdict identity — an effect verdict
                            // re-enters BY CONTRACT on the SAME aggregate that
                            // emitted the trigger. Inject the origin source_id as
                            // the verdict's universal-id self-reference so a
                            // transition (upsert-on-identity, e.g. Order.Authorize)
                            // transitions the REAL order instead of minting a
                            // phantom. Twin of run_host_pass's identical inject.
                            vattrs.insert("id".to_string(), Value::Str(d.source_id.clone()));
                            let _ = self.dispatch(verdict, vattrs);
                        }
                        // Reached a verdict == HANDLED -> MarkDelivered (terminal).
                        let mut md = HashMap::new();
                        md.insert("delivery_id".to_string(), Value::Str(d.delivery_id.clone()));
                        let _ = self.framework_mut().dispatch_impl("MarkDelivered", md);
                    }
                }
            }
        }
        drained
    }

    /// On wasm32 the Worker has no out-of-process handler host (no process
    /// spawning in a CF Worker), so the out-of-process drain is a structural
    /// no-op. Two-color stub : same signature, host runs the real drain.
    #[cfg(target_arch = "wasm32")]
    pub fn drain_outbound_to_quiescence(&mut self) -> usize { 0 }

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

                // deciderate Layer 0b — fan out the primary trigger when the
                // policy declares `for_each: { from: "Agg.query" }` : sweep the
                // query and fire `cmd` once per record, merging the record's
                // fields into the dispatch data. No for_each = a single pass.
                let primary_records: Vec<HashMap<String, Value>> = match &trigger.for_each {
                    Some(spec) => {
                        let mut q_attrs: HashMap<String, String> = HashMap::new();
                        for (k, vspec) in &spec.query_inputs {
                            if let Some(v) = self.evaluate_value_spec(vspec, event, "", "", None) {
                                q_attrs.insert(k.clone(), v.to_string());
                            }
                        }
                        self.sweep_records(spec, &q_attrs)
                    }
                    None => vec![HashMap::new()],
                };
                let primary_sweep = trigger.for_each.is_some();
                for primary_record in &primary_records {
                    // event data, then the policy's `with` literals (which win),
                    // then the swept record's fields (the fan-out binding).
                    let mut data = trigger.event_data.clone();
                    for (k, v) in &trigger.with_data {
                        data.insert(k.clone(), v.clone());
                    }
                    if primary_sweep {
                        for (k, v) in primary_record {
                            data.insert(k.clone(), v.clone());
                        }
                    }
                    storehouse_log::policy_reaction(
                        &policy_name,
                        &event.aggregate_type,
                        &event.name,
                        &event.aggregate_id,
                        &cmd,
                    );
                    self.fire_policy_cascade(&cmd, data, event);
                }

                // deciderate Layer 0b — extra reactions : each `dispatch "Cmd",
                // with: {..}, for_each: {..}` fires after the primary trigger,
                // reusing the same sweep + with-spec machinery as PM dispatches.
                for dispatched in &trigger.extra_dispatches {
                    let iter_records: Vec<HashMap<String, Value>> = match &dispatched.for_each {
                        Some(spec) => {
                            let mut q_attrs: HashMap<String, String> = HashMap::new();
                            for (k, vspec) in &spec.query_inputs {
                                if let Some(v) = self.evaluate_value_spec(vspec, event, "", "", None) {
                                    q_attrs.insert(k.clone(), v.to_string());
                                }
                            }
                            self.sweep_records(spec, &q_attrs)
                        }
                        None => vec![HashMap::new()],
                    };
                    let is_sweep = dispatched.for_each.is_some();
                    for record in &iter_records {
                        let iter_arg = if is_sweep { Some(record) } else { None };
                        let mut data: HashMap<String, Value> = HashMap::new();
                        for (key, spec) in &dispatched.with_spec {
                            if let Some(v) = self.evaluate_value_spec(spec, event, "", "", iter_arg) {
                                data.insert(key.clone(), v);
                            }
                        }
                        self.fire_policy_cascade(&dispatched.command_name, data, event);
                    }
                }

                self.policy_engine.complete(&policy_name);
            }
        }
    }

    /// deciderate Layer 0b — fire one policy cascade : inject the refs the
    /// triggered command needs, dispatch it, then run the compute / llm /
    /// process-spawn reaction hooks. The shared per-dispatch tail used by a
    /// policy's primary trigger, its for_each sweep, and every extra dispatch.
    fn fire_policy_cascade(
        &mut self,
        command_name: &str,
        mut data: HashMap<String, Value>,
        event: &Event,
    ) {
        self.inject_refs(
            command_name,
            &event.aggregate_type,
            &event.aggregate_id,
            &mut data,
        );
        let cascade_attrs = data.clone();
        let inner = command_dispatch::dispatch_cascade(
            self,
            command_name,
            data,
            &event.aggregate_type,
            &event.aggregate_id,
        );
        storehouse_log::cascade_step(command_name, &event.aggregate_id, inner.is_ok());
        if let Ok(inner_result) = inner {
            self.drain_policies(&inner_result);
            self.resolve_compute_adapters(&inner_result, command_name);
            self.resolve_llm_adapters(&inner_result, command_name);
            self.resolve_primitive_spawn(&inner_result, command_name, &cascade_attrs, Some(event));
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
                && spec.source_context.as_ref().is_none_or(|ctx| {
                    a.context.as_ref() == Some(ctx)
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

    /// Gated read entry — the query-side mirror of `dispatch`. Runs the SAME
    /// before-gates as a command (authenticate / authorize PDP / service),
    /// keyed on the query name as the action, then calls `resolve_query` (the
    /// UNGATED core). Reads are authorized symmetrically with writes :
    /// `query`(gated) / `resolve_query`(ungated) parallels `dispatch` /
    /// `dispatch_impl`. The ungated core stays the inner path a service-gate's
    /// own check-query uses, so a gate never re-gates itself (no regress).
    /// `scope_to` row-scoping still narrows WHICH rows ; the gate decides
    /// WHETHER the read runs at all. The principal rides the reserved
    /// actor_kind/actor_auth_id keys, exactly as for a command.
    pub fn query(
        &mut self,
        query_name: &str,
        attrs: std::collections::HashMap<String, String>,
    ) -> Result<serde_json::Value, RuntimeError> {
        let mut gate_attrs: HashMap<String, Value> = HashMap::new();
        if let Some(k) = attrs.get(acl_readmodel::KIND_KEY) {
            gate_attrs.insert(acl_readmodel::KIND_KEY.to_string(), Value::Str(k.clone()));
        }
        if let Some(id) = attrs.get(acl_readmodel::AUTH_KEY) {
            gate_attrs.insert(acl_readmodel::AUTH_KEY.to_string(), Value::Str(id.clone()));
        }
        self.authorize_entry(query_name, &mut gate_attrs)?;
        Ok(self.resolve_query(query_name, &attrs))
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
// pub : the SQL-pushdown <-> oracle parity test (storehouse-sqlite crate) asserts
// the adapter's prefilter agrees with this in-memory oracle, so it must be reachable
// cross-crate as `storehouse::runtime::where_matches`.
pub fn where_matches(
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
        // A present-but-NULL field reads as "" — the SAME as a missing field, so
        // a SQL-hydrated NULL (Value::Null, Display "null") and an in-memory
        // absent field compare identically (the parity contract ; otherwise a
        // NULL column would sort as the literal "null").
        Value::Null => String::new(),
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
        // Unescape the source-level string escapes (`\"` -> `"`, `\\` -> `\`).
        // Ruby's own string-literal parsing unescapes these before the DSL ever
        // sees the value, so the Rust side must match or an args payload like
        // `"{\"q\":\"{query}\"}"` reaches serde with literal backslashes and
        // fails JSON parsing — the pre-existing drift the :mcp primitive
        // migration surfaced (every escaped-quote args binding silently hit
        // `[mcp:warn] :args is not JSON` before this).
        let inner = &t[1..t.len() - 1];
        let mut out = String::with_capacity(inner.len());
        let mut chars = inner.chars();
        while let Some(c) = chars.next() {
            if c == '\\' {
                match chars.next() {
                    Some('"') => out.push('"'),
                    Some('\\') => out.push('\\'),
                    Some(other) => {
                        out.push('\\');
                        out.push(other);
                    }
                    None => out.push('\\'),
                }
            } else {
                out.push(c);
            }
        }
        return out;
    }
    if let Some(rest) = t.strip_prefix(':') {
        return rest.to_string();
    }
    t.to_string()
}

/// Reduce a hecksagon binding's `command:` ref to its `Aggregate.Command`
/// tail for matching against a dispatched target. A binding may name its
/// command bare (`"ShellTool.Bash"`) or fully qualified
/// (`"Hecks::Framework::Tools::ShellTool.Bash"`) — both must match the same
/// dispatch, which is always built as `aggregate_type.bare_command` (2-seg).
/// Strip any realm prefix (everything up to the last `::`) before comparing ;
/// without this, an FQN-canonicalized binding silently stops matching and the
/// adapter never fires (the bug that bricked the storehouse door, 2026-06-22).
pub(crate) fn binding_command_tail(c: &str) -> &str {
    c.rsplit("::").next().unwrap_or(c)
}

/// i221-B — convert a serde_json::Map into a HashMap<String, Value>
/// for use as `iter_data` in a sweep dispatch. The sweep records come
/// from `resolve_query` which serializes through serde_json ; this
/// brings them back into the runtime's Value enum so `from_iter
/// (:field)` reads land in the right shape.
/// Resolve an adapter's (possibly relative) handler path to a usable one,
/// trying in order : an ABSOLUTE path as-is ; relative to the aggregates_root
/// (`root`) ; relative to the canonical repo root (where framework `tools/` /
/// `examples/` handlers live) ; relative to CWD. Returns the FIRST that exists,
/// else the root-joined form (so a genuinely-missing handler still yields a
/// stable path the caller's `.exists()` check rejects). The effect drain calls
/// this so a repo-relative handler (e.g. the screenshot DiskBuffer at
/// `tools/web_debug/disk-buffer-handler`) resolves even when the served
/// aggregates_root is some other directory.
#[cfg(not(target_arch = "wasm32"))]
fn resolve_handler_path(root: &str, handler: &str) -> String {
    if std::path::Path::new(handler).is_absolute() {
        return handler.to_string();
    }
    let mut candidates: Vec<std::path::PathBuf> = Vec::new();
    if !root.is_empty() {
        candidates.push(std::path::Path::new(root).join(handler));
    }
    if let Some(repo) = crate::heki::repo_root() {
        candidates.push(repo.join(handler));
    }
    candidates.push(std::path::PathBuf::from(handler)); // CWD-relative
    for c in &candidates {
        if c.exists() {
            return c.to_string_lossy().into_owned();
        }
    }
    candidates
        .into_iter()
        .next()
        .map(|c| c.to_string_lossy().into_owned())
        .unwrap_or_else(|| handler.to_string())
}

