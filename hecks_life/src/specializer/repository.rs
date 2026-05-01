//! Rust-native specializer for `hecks_life/src/runtime/repository.rs`.
//!
//! Reads `Section` rows from the repository_shape fixtures (one row
//! per emitted file section, in `order` sequence) and concatenates
//! them. Each section's `kind` says how to emit :
//!
//!   - `snippet`    — read snippet_path verbatim (no leading-comment
//!                    strip ; method bodies and the module header
//!                    legitimately begin with `///` or `//`)
//!   - `impl_open`  — emit `impl Repository {\n`
//!   - `impl_close` — emit `}\n`
//!   - `blank`      — emit `\n`
//!
//! Repository is the i147 piece-1 target — the first runtime/* file
//! to regenerate from a meta-shape. Unlike dump.rs (15 methods that
//! share one body_kind), repository.rs has 9 wildly-different
//! methods : I/O-mixed persistence, snapshot orchestration,
//! id-strategy branches, and trivial getters. The shape that fits
//! is "ordered list of snippets", which is what this specializer
//! emits — the bluebook describes the surface, the fixtures
//! describe the order, the snippets carry the bytes.
//!
//! Usage:
//!   let rust = repository::emit(repo_root)?;
//!   print!("{}", rust);
//!
//! [antibody-exempt: hecks_life/src/specializer/repository.rs —
//!  i147 piece 1 Rust-native specializer implementation]

use crate::ir::Fixture;
use crate::specializer::util;
use std::error::Error;
use std::path::Path;

const SHAPE_REL: &str =
    "codegen/repository_shape/fixtures/repository_shape.fixtures";

pub fn emit(repo_root: &Path) -> Result<String, Box<dyn Error>> {
    let shape = repo_root.join(SHAPE_REL);
    let fixtures = util::load_fixtures(&shape)?;
    let sections = util::by_aggregate_sorted(&fixtures, "Section", "order");

    let mut out = String::new();
    for section in sections {
        out.push_str(&emit_section(repo_root, section)?);
    }
    Ok(out)
}

fn emit_section(repo_root: &Path, section: &Fixture) -> Result<String, Box<dyn Error>> {
    match util::attr(section, "kind") {
        "snippet" => {
            let path = repo_root.join(util::attr(section, "snippet_path"));
            util::read_snippet_raw(&path)
        }
        "impl_open" => Ok("impl Repository {\n".to_string()),
        "impl_close" => Ok("}\n".to_string()),
        "blank" => Ok("\n".to_string()),
        other => Err(format!("unknown Section kind: {}", other).into()),
    }
}
