//! Rust-native specializer for `hecks_life/src/behaviors_fixtures.rs`.
//!
//! i147 wave 2 target — the test-runner-side .fixtures auto-loader
//! (locate / parse / apply) regenerated from the
//! `behaviors_fixtures_shape` bluebook + ordered `.rs.frag` snippets.
//!
//! Design — section-as-snippet :
//!   The shape declares one `Section` row per ordered code section in
//!   the target. Each row's `snippet_path` points at a `.rs.frag`
//!   under `capabilities/behaviors_fixtures_shape/snippets/`. The
//!   specializer sorts sections by `order`, reads each snippet
//!   verbatim (`read_snippet_raw` — NOT `read_snippet_body` — because
//!   each section opens with `///` doc comments that are file content,
//!   not doc-strip fodder), and concatenates HEADER + snippets to
//!   produce byte-identical output.
//!
//! Mirrors `specializer/heki_query.rs` exactly ; same body_kind, same
//! flow, different shape + snippets.
//!
//! Usage :
//!   let rust = behaviors_fixtures::emit(repo_root)?;
//!   print!("{}", rust);
//!
//! [antibody-exempt: hecks_life/src/specializer/behaviors_fixtures.rs —
//!  Rust-native specializer module ; one match arm in
//!  `specializer/mod.rs` claims it. Retires when the specializer
//!  itself is regenerated from a meta-shape (i78).]

use crate::specializer::util;
use std::error::Error;
use std::path::Path;

const SHAPE_REL: &str =
    "codegen/behaviors_fixtures_shape/fixtures/behaviors_fixtures_shape.fixtures";

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

const HEADER: &str = r#"//! Behaviors fixtures auto-loader (i4 gap 8).
//!
//! The behaviors runner finds a sibling `.fixtures` file for a given
//! `.behaviors` path and applies its records into a fresh runtime
//! before each test runs. Cross-aggregate cascades that read state
//! seeded by another aggregate's fixtures no longer need explicit
//! `setup` chains in every test.
//!
//! Discovery (in order):
//!   1. `<dir>/<stem>.fixtures`              — flat sibling
//!   2. `<dir>/fixtures/<stem>.fixtures`     — conventional subdir
//!
//! Parity: mirrors `lib/hecks/behaviors/fixtures_loader.rb`. Same
//! discovery rules, same seed convention (ids "1", "2", … in source
//! order), same "first fixture per aggregate wins the in-scope slot".
//!
//! [antibody-exempt: test runner auto-loads fixtures for cross-aggregate
//! cascades (i4 gap 8); retires when behaviors runner ports to
//! bluebook-dispatched form]

use crate::fixtures_ir::FixturesFile;
use crate::fixtures_parser;
use crate::runtime::{AggregateState, Runtime, Value};
use std::collections::HashMap;
use std::path::PathBuf;

"#;
