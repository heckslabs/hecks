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
mod command_dispatch;
mod event_bus;
pub mod loop_driver;
pub mod pm_engine;
mod interpreter;
pub mod adapter_io;
pub mod adapter_llm;
pub mod adapter_registry;
pub mod adapter_terminal;
pub mod shell_dispatcher;
mod middleware;
mod policy_engine;
mod projection;
mod repository;
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
// i629 — :exec adapter family kernel hook. One behavior :
// perform_exec (run a local program, capture stdout/exit, cascade).
// Wired below via resolve_exec_adapters (mirrors the WIRED
// :claude_tool arm, not the unwired i557 registry path). Closes
// i629 : Inbox.Check's :exec binding runs bin/inbox_poll.mjs so the
// 900s loop dispatch IS the Gmail poll.
pub mod exec_dispatcher;
pub mod compute_functions;
// i557 — Phase-2 framework runtime. Walks
// `hecks_conception/aggregates/framework/{adapter_families,behavior_kinds}/`
// at boot and builds a typed registry of adapter families + behavior
// kinds + native kernel hooks. Part 1 lands the registry surface +
// boot wiring + kernel-hook seed for `invoke_claude_tool` ; part 2
// retires the hardcoded `:claude_tool` shortcut in `Runtime::dispatch`.
pub mod framework_registry;
// i622 — StoreHouse stdout logger. One-line records on stdout per
// dispatch, event, cascade, policy. Level gated by STOREHOUSE_LOG
// (quiet/normal/verbose). All four surfaces and the MCP child stderr
// route through this module so stdout is the single audit stream.
pub mod storehouse_log;

pub use aggregate_state::AggregateState;
pub use command_dispatch::CommandResult;
pub(crate) use command_dispatch::apply_lifecycle_default;
pub use event_bus::{Event, EventBus};
pub use middleware::{CommandContext, MiddlewareStack, Phase};
pub use policy_engine::{PolicyEngine, PolicyTrigger};
pub use pm_engine::{PMBinding, PMEngine, PMInstanceState, PMTrigger};
pub use projection::Projection;
pub use repository::Repository;

use crate::ir::Domain;
use crate::hecksagon_ir::Hecksagon;
use std::collections::HashMap;
