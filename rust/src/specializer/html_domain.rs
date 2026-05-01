//! Rust-native specializer for `rust/src/server/html_domain.rs`.
//!
//! i147 Wave 9-A target — the per-domain detail page emitter,
//! regenerated from the `html_domain_shape` bluebook + ordered
//! `.rs.frag` snippets at codegen/html_domain_shape/.
//!
//! Design — section-as-snippet (mirrors assemble_shape) :
//!   The shape declares one `Section` row per ordered code section
//!   in the target. Each row's `snippet_path` points at a `.rs.frag`
//!   under `codegen/html_domain_shape/snippets/`. The specializer
//!   sorts sections by `order`, reads each snippet verbatim
//!   (`read_snippet_raw` — NOT `read_snippet_body` — because each
//!   snippet's trailing blank line is the section separator), and
//!   concatenates HEADER + snippets to produce byte-identical output.
//!
//! Family decision : SOLO. The html_*.rs siblings under
//! rust/src/server/ (workflow, fixtures, kpi, usage, shared, sidebar,
//! scripts, narration, icons, help, rules, wizard, policy_chain) all
//! emit HTML strings, but their input IR + helper signatures + DOM
//! templates diverge — there's no two-consumer template that would
//! justify inventing `html_section` / `html_form_template` /
//! `string_table` body_kinds today. The post-W6 plan flagged the
//! family option but explicitly defers it. Solo retirement keeps the
//! Section row vocabulary uniform across the i147 corpus ; promote
//! to a family when two siblings actually share a real template.
//!
//! Why HEADER as a const :
//!   The doc + imports prelude is short, stable, and not naturally
//!   tabular ; baking it as a Rust const keeps the shape's tabular
//!   rows uniform (one body_kind, one path attribute). When a future
//!   shape lands that captures imports as data, the HEADER const
//!   retires into a row.
//!
//! Usage :
//!   let rust = html_domain::emit(repo_root)?;
//!   print!("{}", rust);
//!
//! [antibody-exempt: rust/src/specializer/html_domain.rs —
//!  i147 Wave 9-A — Rust-native specializer for server/html_domain.rs]

use crate::specializer::util;
use std::error::Error;
use std::path::Path;

const SHAPE_REL: &str =
    "codegen/html_domain_shape/fixtures/html_domain_shape.fixtures";

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
            other => {
                return Err(format!("unknown body_kind: {}", other).into());
            }
        }
    }
    Ok(out)
}

const HEADER: &str = r#"//! HTML domain page — detail view for a single domain
//!
//! Shows modules (aggregates), commands, lifecycle states, and records
//! for one domain. Forms submit to the JSON dispatch endpoint.
//!
//! Usage:
//!   let page = generate_domain_page(&rt, &all_domains);

use crate::runtime::Runtime;
use crate::ir::Fixture;
use std::cell::RefCell;
use std::collections::HashMap;
use super::html_shared::{wrap_page, sidebar_links, display_name, module_icon, esc};
use super::html_workflow::workflow_pipeline;
use super::html_fixtures::{module_fixtures, fixtures_section};
use super::html_kpi::kpi_cards;
use super::html_usage::usage_section;

"#;
