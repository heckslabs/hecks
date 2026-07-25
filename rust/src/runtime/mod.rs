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
mod event_surface;
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
mod adapter_wiring;
mod auth_gates;
mod authz;
mod boot;
mod boot_persistent;
mod cascade_driver;
mod cascade_record;
mod dispatch_core;
mod dispatch_doors;
mod read_surface;
mod effect_outbound;
mod errors;
mod pm_dispatch;
mod policy_cascade;
mod query_match;
use crate::hecksagon_ir::Hecksagon;
use crate::ir::Domain;
use std::collections::HashMap;

mod runtime_state;
pub use runtime_state::{BackendInfo, PendingReaction, Runtime};
mod runtime_util;
pub(crate) use runtime_util::{binding_command_tail, strip_quotes_or_colon};
use runtime_util::{dispatch_detail_args_json, dispatch_detail_state_json, live_pids, pascal_to_phrase, trigram_sim};
#[cfg(not(target_arch = "wasm32"))]
use runtime_util::resolve_handler_path;
pub use query_match::{repo_key, repo_lookup_key, where_matches};
use query_match::{resolve_limit_value, resolve_state_field};
mod ref_injection;
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

impl Runtime {
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

/// Macro for building attribute maps
#[macro_export]
macro_rules! attrs {
    ($($key:expr => $val:expr),* $(,)?) => {{
        let mut map = std::collections::HashMap::new();
        $(map.insert($key.to_string(), $val);)*
        map
    }};
}

