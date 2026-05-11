//! Rust-native specializer for `storehouse/src/parse_blocks.rs`.
//!
//! i147 Wave 3-C target (sister to parser.rs) — kernel-surface
//! recursive-descent block parsers (section / command / value_object /
//! entity / lifecycle / attribute / fixture / mutation) regenerated
//! from the `parse_blocks_shape` bluebook + ordered `.rs.frag` snippets.
//!
//! Design — section-as-snippet (mirrors heki_query / discover / parser) :
//!   The shape declares one `Section` row per top-level fn in the
//!   target. Each row's `snippet_path` points at a `.rs.frag` under
//!   `codegen/parse_blocks_shape/snippets/`. The specializer sorts
//!   sections by `order`, reads each snippet verbatim
//!   (`read_snippet_raw` — NOT `read_snippet_body` — because each
//!   snippet's trailing blank line is the section separator), and
//!   concatenates HEADER + snippets to produce byte-identical output.
//!
//! Path B (two shapes) sibling — see specializer/parser.rs for the
//! state-machine dispatch half of the bluebook parser. This module
//! covers the recursive descent half : 15 ordered top-level functions,
//! each one section.
//!
//! Why HEADER as a const :
//!   Same justification as heki_query / parser : doc + imports prelude
//!   is short, stable, and not naturally tabular. Baking it here keeps
//!   shape rows uniform.
//!
//! Usage :
//!   let rust = parse_blocks::emit(repo_root)?;
//!   print!("{}", rust);
//!
//! [antibody-exempt: storehouse/src/specializer/parse_blocks.rs —
//!  i147 Wave 3-C — Rust-native specializer for parse_blocks.rs]

use crate::specializer::util;
use std::error::Error;
use std::path::Path;

const SHAPE_REL: &str =
    "codegen/parse_blocks_shape/fixtures/parse_blocks_shape.fixtures";

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

const HEADER: &str = r#"//! Block parsers — parse command, value_object, policy, lifecycle, attribute, mutation
//!
//! Each function takes a slice of lines starting at the block opener
//! and returns the parsed structure plus lines consumed.
//!
//! [antibody-exempt: i106 dsl-mutation-primitives — kernel-surface
//!  parser extension that recognizes `multiply:`, `clamp:`, and `decay:`
//!  on `then_set`. Same retirement contract as ir.rs : the .rs surface
//!  exists to enable pulse_organs.bluebook + consolidate retirement
//!  (i80 cli-routing-as-bluebook).]
//!
//! [antibody-exempt: i226 parse-where-comparator-hash-form — kernel-surface
//!  parser extension that recognizes `where(field: { lt|lte|gt|gte|ne: value })`
//!  hash-form comparators. The IR's WhereOp already carries every variant ;
//!  this is the parser side wiring that makes them reachable from .bluebook.
//!  Without it, queries like `Synapse.cold` (where last_fired_at < cutoff)
//!  cannot be expressed as first-class queries, and consolidate.sh /
//!  rem_branch.sh cannot retire (i221 / i222). Same retirement contract.]

use crate::ir::*;
use crate::parser_helpers::*;

"#;
