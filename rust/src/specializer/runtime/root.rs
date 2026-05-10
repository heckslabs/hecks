//! Rust-native specializer for `rust/src/runtime/mod.rs`.
//!
//! i147 Wave 5-B target — the runtime kernel root regenerated from
//! the `runtime_shape` bluebook + ordered `.rs.frag` snippets +
//! per-method / per-phase rows.
//!
//! Design — three-level section / method / phase nesting. The shape
//! declares one `Section` row per top-level partition in the file, in
//! source order. Each row's `body_kind` picks the emission template :
//!
//! ```text
//!     verbatim_section — read snippet_path raw, emit unchanged.
//!                        Used for the Runtime struct, the Value enum
//!                        + impls, the RuntimeError enum + Display
//!                        impl, the attrs! macro, the repo_key /
//!                        repo_lookup_key helpers, and the trigram
//!                        helpers.
//!
//!     runtime_impl     — emit the `impl Runtime { … }` block by
//!                        walking RuntimeMethod rows in `order`
//!                        ascending, wrapped by the impl opener and
//!                        closing brace.
//! ```
//!
//! Each RuntimeMethod row's body_kind in turn picks :
//!
//! ```text
//!     verbatim_method  — read snippet_path raw, emit unchanged. The
//!                        snippet is the full method (incl. leading
//!                        doc comment when present and trailing blank
//!                        when present — separator handling is encoded
//!                        in the snippet itself).
//!     boot_pipeline    — emit `pub fn boot_with_data_dir(domain,
//!                        data_dir) -> Self { … }` by walking
//!                        BootPhase rows in `order` ascending. The
//!                        function header and closing brace + trailing
//!                        blank are emitted by the template ; phase
//!                        snippets carry the inter-phase blank-line
//!                        separators inline.
//! ```
//!
//! Real compression : adding a boot phase (e.g. wire_adapters when the
//! adapter wiring lifts out of terminal/io into the boot pipeline) is
//! a single fixture row + snippet pair, not a hand-edit to the boot
//! function. Same for adding a Runtime impl method.
//!
//! Usage :
//!
//! ```ignore
//!   let rust = runtime::root::emit(repo_root)?;
//!   print!("{}", rust);
//! ```
//!
//! [antibody-exempt: rust/src/specializer/runtime/root.rs —
//!  i147 Wave 5-B Rust-native specializer for runtime/mod.rs.
//!  Retires when the specializer itself is regenerated from a
//!  meta-shape (i78).]

use crate::ir::Fixture;
use crate::specializer::util;
use std::error::Error;
use std::path::Path;

const SHAPE_REL: &str =
    "codegen/runtime_shape/fixtures/runtime_shape.fixtures";

pub fn emit(repo_root: &Path) -> Result<String, Box<dyn Error>> {
    let shape = repo_root.join(SHAPE_REL);
    let fixtures = util::load_fixtures(&shape)?;

    let sections = util::by_aggregate_sorted(&fixtures, "Section", "order");

    let mut out = String::new();
    out.push_str(HEADER);
    for sec in &sections {
        match util::attr(sec, "body_kind") {
            "verbatim_section" => {
                let snippet_path = repo_root.join(util::attr(sec, "snippet_path"));
                let body = util::read_snippet_raw(&snippet_path)?;
                out.push_str(&body);
            }
            "runtime_impl" => {
                out.push_str(&emit_runtime_impl(repo_root, &fixtures)?);
            }
            other => {
                return Err(format!("unknown body_kind: {}", other).into());
            }
        }
    }
    Ok(out)
}

/// Emit the `impl Runtime { … }` block. Walks RuntimeMethod rows in
/// `order` ascending, dispatching each row by its own body_kind
/// (verbatim_method or boot_pipeline). The impl opener and closing
/// brace are emitted by this template ; method-level blank-line
/// separators are encoded in the snippets themselves (each verbatim
/// method snippet ends with a trailing blank ; the boot_pipeline
/// emitter likewise appends a trailing blank after its closing brace).
///
/// Two methods deviate from the trailing-blank pattern :
///   - query_projection ends with `    }\n` and is followed
///     immediately by resolve_query's leading doc comment with NO
///     intervening blank line. Its snippet therefore has no trailing
///     blank, and resolve_query's snippet has no leading blank.
///   - run_interactive (the last method) ends with `    }\n` directly
///     adjacent to the impl block's closing `}\n`. Its snippet has
///     no trailing blank, and the closing brace below provides the
///     hand-off to the next Section.
fn emit_runtime_impl(
    repo_root: &Path,
    fixtures: &[Fixture],
) -> Result<String, Box<dyn Error>> {
    let methods = util::by_aggregate_sorted(fixtures, "RuntimeMethod", "order");

    let mut out = String::new();
    out.push_str("impl Runtime {\n");
    for m in &methods {
        match util::attr(m, "body_kind") {
            "verbatim_method" => {
                let snippet_path = repo_root.join(util::attr(m, "snippet_path"));
                let body = util::read_snippet_raw(&snippet_path)?;
                out.push_str(&body);
            }
            "boot_pipeline" => {
                out.push_str(&emit_boot_pipeline(repo_root, fixtures)?);
            }
            other => {
                return Err(format!("unknown method body_kind: {}", other).into());
            }
        }
    }
    out.push_str("}\n");
    Ok(out)
}

/// Emit the `pub fn boot_with_data_dir(domain, data_dir) -> Self { … }`
/// function by walking BootPhase rows in `order` ascending. The
/// function signature and closing brace + trailing blank line (which
/// separates boot_with_data_dir from the next method) are emitted by
/// this template ; phase snippets carry the inter-phase blank lines
/// internally (each phase snippet except the last ends with a trailing
/// blank line that becomes the separator between phases).
fn emit_boot_pipeline(
    repo_root: &Path,
    fixtures: &[Fixture],
) -> Result<String, Box<dyn Error>> {
    let phases = util::by_aggregate_sorted(fixtures, "BootPhase", "order");

    let mut out = String::new();
    out.push_str("    pub fn boot_with_data_dir(domain: Domain, data_dir: Option<String>) -> Self {\n");
    for p in &phases {
        let snippet_path = repo_root.join(util::attr(p, "snippet_path"));
        let body = util::read_snippet_raw(&snippet_path)?;
        out.push_str(&body);
    }
    // Closing brace of the function + trailing blank to separate from
    // the next method (`dispatch`). The phase_4 snippet ends with the
    // Runtime literal's closing `        }` so this template emits the
    // function-level closing `    }` + the inter-method blank.
    out.push_str("    }\n\n");
    Ok(out)
}

const HEADER: &str = r#"//! Hecks Runtime — executes domains from IR
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
pub mod compute_functions;

pub use aggregate_state::AggregateState;
pub use command_dispatch::CommandResult;
pub use event_bus::{Event, EventBus};
pub use middleware::{CommandContext, MiddlewareStack, Phase};
pub use policy_engine::{PolicyEngine, PolicyTrigger};
pub use pm_engine::{PMBinding, PMEngine, PMInstanceState, PMTrigger};
pub use projection::Projection;
pub use repository::Repository;

use crate::ir::Domain;
use crate::hecksagon_ir::Hecksagon;
use std::collections::HashMap;
"#;
