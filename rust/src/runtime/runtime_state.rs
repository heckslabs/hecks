//! runtime_state — the runtime STATE SHAPE : the Runtime struct itself (the
//! domain, the repositories, the engines, the outboxes, the wired surfaces —
//! every field documented where it lives), plus BackendInfo and
//! PendingReaction. The behaviors live in the concern casks ; this cask owns
//! the shape they all share.
//!
//! Cask extracted VERBATIM from runtime/mod.rs (shrink-mod phase B, wave 3).
//!
//! [antibody-exempt: rust/src/runtime/runtime_state.rs — kernel-floor state
//!  shape (types with their field docs), relocated verbatim from mod.rs
//!  blanket.]

use super::*;

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
