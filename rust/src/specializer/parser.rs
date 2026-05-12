//! Rust-native specializer for `rust/src/parser.rs`.
//!
//! i147 Wave 3-C target — kernel-surface bluebook parser (top-level
//! Domain assembly + line-by-line state machine dispatch) regenerated
//! from the `parser_shape` bluebook + ordered `.rs.frag` snippets.
//!
//! Design — section-as-snippet (mirrors heki_query / discover) :
//!   The shape declares one `Section` row per ordered code section in
//!   the target. Each row's `snippet_path` points at a `.rs.frag`
//!   under `codegen/parser_shape/snippets/`. The specializer sorts
//!   sections by `order`, reads each snippet verbatim
//!   (`read_snippet_raw` — NOT `read_snippet_body` — because each
//!   snippet's trailing blank line is the section separator), and
//!   concatenates HEADER + snippets to produce byte-identical output.
//!
//! Path B (two shapes) chosen — sister specializer for parse_blocks.rs
//! lives next door at specializer/parse_blocks.rs. parser_shape covers
//! the state-machine dispatch loop ; parse_blocks_shape covers the
//! recursive-descent block parsers. Same body_kind on both (the
//! survey's `state_machine_dispatch` vs `block_parser` distinction is
//! captured by the shape boundary, not by emitter logic).
//!
//! Why HEADER as a const :
//!   The doc + imports prelude is short, stable, and not naturally
//!   tabular ; baking it as a Rust const keeps the shape's tabular
//!   rows uniform (one body_kind, one path attribute). Mirrors the
//!   heki_query / discover / conceiver_generator pattern.
//!
//! Usage :
//!   let rust = parser::emit(repo_root)?;
//!   print!("{}", rust);
//!
//! [antibody-exempt: rust/src/specializer/parser.rs —
//!  i147 Wave 3-C — Rust-native specializer for parser.rs]

use crate::specializer::util;
use std::error::Error;
use std::path::Path;

const SHAPE_REL: &str =
    "codegen/parser_shape/fixtures/parser_shape.fixtures";

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

const HEADER: &str = r#"//! Bluebook parser — reads .bluebook files into IR
//!
//! Parses the Ruby-hosted DSL by pattern matching on the structure.
//! Not a full Ruby parser — just enough to read Bluebook declarations.
//! Block parsers live in parse_blocks.rs.
//!
//! [antibody-exempt: parser.rs — kernel-surface bluebook parser;
//!  storehouse specialize parser regenerates this file byte-for-byte from
//!  parser_shape fixtures. Edit here seeds the golden fixture; update
//!  parser_shape to match. Subsumes unique:true singleton pattern via
//!  identified_by natural-key dispatch.]

use crate::ir::*;
use crate::parser_helpers::*;
use crate::parse_blocks::*;

"#;
