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
//!
//! ## Module map — what lives where (relocated from the index body ;
//! the per-cask detail also lives in each cask file's own doc-header)
//!
//! adapter_terminal — host-only stdin/stdout REPL shim (drives
//! `crate::run_stdin_loop`, which is gated out of wasm). The Worker
//! has no terminal.
//! The persistence-resolution `impl Runtime` methods (dump_backend_map,
//! unwired_aggregates) live in this hand-written child module, not in mod.rs.
//! Inherent impl in a child module attaches to Runtime. (Was a runtime_shape
//! codegen artifact until 2026-06-27.)
//! i728 file-split cluster 4 — the event/outbox driving methods
//! (enqueue_and_drain, fire_driving_cron_ticks) generated into this child module.
//! i750 out-of-process-adapter pump — `.world`→handler-child-env folding,
//! relocated from `run_host::config` so the OutboundEvent drain
//! (`reaction::pump_outbound_events`) resolves a handler's env without the
//! soon-to-retire standalone host. `run_host::config` re-exports `map_config`.
//! i728 file-split cluster 4b — Phase-3 reaction delivery (react, react_ports,
//! pump) generated into this child module.
//! i728 file-split cluster 7 — context-qualified read side (all_qualified,
//! resolve_query_qualified) generated into this child module.
//! value_convert — Value<->JSON conversion + coercion cask (shrink-mod phase B
//! wave 1). Re-exported at the SAME paths the fns always had, so no caller
//! changes : the pub trio stays `runtime::value_to_json_string` etc., the
//! crate-internal value_to_json stays `pub(crate)`, and the private helpers
//! stay reachable by mod.rs + child modules through this use.
//! errors — RuntimeError + its Display (shrink-mod phase B cask). Same path :
//! `runtime::RuntimeError` resolves through this re-export unchanged.
//! boot / boot_persistent — the constructor casks (shrink-mod phase B).
//! i-lazy — boot-map lazy hydration. Wraps Repository in a OnceCell so
//! boot constructs all 458 repos WITHOUT touching disk ; each repo's
//! load_persisted runs on first access. Kills the ~4.2s eager-hydration
//! tax on a single-shot dispatch (which touches exactly one repo).
//! The persistence PORT (hexagon) — wired backends implement this trait and the
//! kernel holds them as `Box<dyn PersistenceAdapter>`, naming no concrete engine.
//! i220 sub-gap 5 (compute-adapter-primitive) — sibling of llm_dispatcher
//! for local computation. Adapters declared as `:compute` in a hecksagon
//! route through `compute_dispatcher::call` which resolves
//! `function_name` against the static `compute_functions` registry.
//! i593 — :mcp adapter family kernel hook. One behavior :
//! invoke_mcp_tool (open stdio MCP session, call named tool with
//! args, route response back into the cascade). Sibling to
//! claude_tool_dispatcher ; registered into i557's framework
//! registry alongside it. Shell hooks reach this via the new
//! `storehouse mcp` subcommand family in main.rs.
//! i569 — :web_tool adapter family kernel hook. Two behaviors :
//! perform_web_fetch (curl HTTP GET, URL-safety gated) and
//! perform_web_search (DuckDuckGo HTML-lite). Sibling to
//! claude_tool_dispatcher ; registered into i557's framework registry
//! once that lands. This module exposes `lookup_hook` +
//! `WEB_TOOL_BEHAVIOR_NAMES` for the registry to consume — `Runtime::
//! dispatch` is deliberately NOT modified to call into it.
//! i629 — the kernel-floor exec leaf. One behavior : perform_exec
//! (run a local program, capture stdout/exit). The bespoke
//! `resolve_exec_adapters` arm that used to drive it is RETIRED
//! (adapters-as-bluebook, plan: structured-pondering-pie) ; this leaf
//! is now reached only through `resolve_primitive_spawn` (the generic
//! `Primitive::Process.Spawn` hook). Every former `:exec` binding —
//! Inbox.Check, ProcessMacrophage.Sweep/Heal, the fibroblast sweep —
//! is now an ordinary aggregate-qualified bluebook policy firing
//! `Primitive::Process.Spawn`. The spawn syscall is the only imperative
//! remainder ; the adapter PROTOCOL is plain bluebook policy/cascade.
//! Sprint 14 actor-model quartet — per-aggregate-instance mailboxes,
//! async event delivery, per-actor failure isolation, causal ordering.
//! The mailbox layer wraps (not replaces) the existing synchronous
//! dispatch path : command dispatch still returns synchronously (sync
//! feel), event-driven cascades route through the registry. See
//! `actor/mod.rs` for the architectural shape ; the 4 smoke tests in
//! `actor::tests` flip each story's DiD gate.
//!
//! Host-only : the tokio substrate (sprint-14 tokio-mailbox-substrate)
//! is cfg-gated on non-wasm32. tokio has no wasm32-unknown-unknown
//! target ; the Cloudflare-worker build never reaches the actor
//! dispatch path so the gate is structurally safe.
//! Sprint 14 — sibling of driven_adapter_resolver. Fires `driving on`
//! adapter handlers triggered by EXTERNAL signals (cron tick first ;
//! http_post / file_watch parse but are runtime stubs pending listener
//! wiring). See module-level doc for v1 scope.
//! The pure tick-counter core of `storehouse drive` (the single-owner
//! interval scheduler that fires `driving on interval` handlers live).
//! The pure 5-field cron-expression matcher — sibling of drive_scheduler for
//! the CRON kind. `storehouse drive` asks `is_due(expr, now)` to fire
//! `driving on cron` handlers only on a matching minute.
//! The append-only one-line-per-event shard backing the out-of-process
//! Event Log (shards-plus-merge topology). Format + writer + offset reader.
//! Phase 2 of the where() overhaul — filtered streaming scan of the Event
//! Log : hydrate only matching lines (O(matches)) instead of the whole Log.
//! Phase 3 of the where() overhaul — the offset index for the Event Log, so
//! Replay SEEKS to an aggregate's events instead of streaming. Safe by
//! construction (commit-marker + full-scan fallback ; no false negatives).
//! SQL pushdown (sql_query / sqlite_query) + its parity tests live in the
//! storehouse-sqlite crate now — the persistence adapter owns its query surface
//! and its rusqlite dependency. The lib names no engine.
//! Phase 4 of the where() overhaul — the CausationTrace lineage traversal
//! (resolve_query_qualified's recursive branch), tested over a seeded chain.
//! The FORWARD half — ConsequenceTree fans out over the reverse index
//! (causation_id -> children), tested over seeded trees a live cascade can't shape.
//! The merge half : tail N single-writer shards into the global ordered Log.
//! i557 — Phase-2 framework runtime. Walks
//! `hecks_conception/aggregates/framework/{adapter_families,behavior_kinds}/`
//! at boot and builds a typed registry of adapter families + behavior
//! kinds + native kernel hooks. Part 1 lands the registry surface +
//! boot wiring + kernel-hook seed for `invoke_claude_tool` ; part 2
//! retires the hardcoded `:claude_tool` shortcut in `Runtime::dispatch`.
//! sprint-14 (storehouse-primitive-conception) — runtime index of the
//! imperative kernel-floor leaves. Mirrors the Storehouse::Primitive
//! bluebook records ; seeded at boot with the current hand-coded
//! primitives (Process.Spawn / ClaudeTool.Invoke / WebTool.* / Compute /
//! Llm / Shell / Sms). The runtime consults it BEFORE running its
//! hard-coded match arms so a macrophage check can confirm every
//! imperative leaf has a matching declaration.
//! i622 — StoreHouse stdout logger. One-line records on stdout per
//! dispatch, event, cascade, policy. Level gated by STOREHOUSE_LOG
//! (quiet/normal/verbose). All four surfaces and the MCP child stderr
//! route through this module so stdout is the single audit stream.

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
#[cfg(not(target_arch = "wasm32"))]
pub mod adapter_terminal;
pub mod shell_dispatcher;
mod middleware;
mod policy_engine;
mod projection;
mod repository;
mod persistence_resolution;
mod event_driving;
pub mod adapter_env;
mod reaction;
mod query;
/// Framework substrate — the collaborator holding the kernel's own aggregates
/// (the event Log, the veto audit, the outbox), so the runtime never depends on
/// a user's domain having merged them.
mod framework_substrate;
/// Event sourcing — per-delta Event append, causation lineage, consolidation.
/// (Distinct from `crate::event_log`, the storage primitive it writes through.)
mod event_sourcing;
mod event_surface;
mod value;
pub use value::Value;
mod value_convert;
pub use value_convert::{attr_value_from_str, value_from_json_str, value_to_json_string};
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
mod policy_drain;
mod policy_eval;
pub use errors::RuntimeError;
use errors::PolicyOutcome;
pub(crate) use value_convert::value_to_json;
use value_convert::{json_obj_to_value_map, json_to_value_recursive, parse_payload_attrs};
mod lazy_repository;
pub mod persistence_adapter;
pub mod seed_loader;
pub mod llm_dispatcher;
pub mod llm_providers;
pub mod prompt_scaffolder;
pub mod compute_dispatcher;
pub mod claude_tool_dispatcher;
pub mod mcp_dispatcher;
pub mod sms_dispatcher;
pub mod web_tool_dispatcher;
pub mod exec_dispatcher;
pub mod driven_adapter_resolver;
#[cfg(not(target_arch = "wasm32"))]
pub mod actor;
pub mod driving_adapter_resolver;
pub mod drive_scheduler;
pub mod cron_schedule;
pub mod event_shard;
pub mod projection_fold;
pub mod event_log;
pub mod event_log_query;
pub mod event_log_index;
#[cfg(all(test, not(target_arch = "wasm32")))]
mod causation_trace_tests;
#[cfg(all(test, not(target_arch = "wasm32")))]
mod consequence_tree_tests;
pub mod event_merge;
pub mod compute_functions;
pub mod framework_registry;
pub mod primitive_registry;
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
