//! Rust-native specializer for `rust/src/runtime/repository.rs`.
//!
//! Reads `Section` rows from the repository_shape fixtures (one row
//! per emitted file section, in `order` sequence) and concatenates
//! them. Each section's `kind` says how to emit :
//!
//!   - `snippet`               — read snippet_path verbatim (no
//!                               leading-comment strip ; method bodies
//!                               and the module header legitimately
//!                               begin with `///` or `//`)
//!   - `impl_open`             — emit `impl Repository {\n`
//!   - `impl_close`            — emit `}\n`
//!   - `blank`                 — emit `\n`
//!   - `store_accessor_block`  — emit the trivial-accessor family
//!                               (find / find_mut / all / count) from
//!                               the `Accessor` rows, picking the body
//!                               template per row's `accessor_kind`.
//!
//! Repository is the i147 Wave 1 / Wave 5-C target — the first
//! runtime/* file to regenerate from a meta-shape, and the wave that
//! pulls REAL compression out of the trivial-accessor family. The
//! load-bearing I/O methods (load_persisted, save, delete,
//! id_for_command, new_with_context, heki_path_self) keep their
//! per-method snippets because their bodies are honestly sui-generis.
//!
//! Usage:
//!   let rust = repository::emit(repo_root)?;
//!   print!("{}", rust);
//!
//! [antibody-exempt: rust/src/specializer/repository.rs —
//!  i147 piece 1 / Wave 5-C Rust-native specializer implementation]

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
        out.push_str(&emit_section(repo_root, &fixtures, section)?);
    }
    Ok(out)
}

fn emit_section(
    repo_root: &Path,
    fixtures: &[Fixture],
    section: &Fixture,
) -> Result<String, Box<dyn Error>> {
    match util::attr(section, "kind") {
        "snippet" => {
            let path = repo_root.join(util::attr(section, "snippet_path"));
            util::read_snippet_raw(&path)
        }
        "impl_open" => Ok("impl Repository {\n".to_string()),
        "impl_close" => Ok("}\n".to_string()),
        "blank" => Ok("\n".to_string()),
        "store_accessor_block" => emit_store_accessors(fixtures),
        other => Err(format!("unknown Section kind: {}", other).into()),
    }
}

/// Emit the trivial-accessor family — one method per `Accessor` row in
/// `order` ascending, separated by blank lines. The four rows
/// (find / find_mut / all / count) all delegate straight through to the
/// internal HashMap ; `accessor_kind` picks the one-liner body. No
/// trailing blank — the caller's next Section is `impl_close` and the
/// existing tracked source has no blank between the last accessor and
/// the closing brace.
fn emit_store_accessors(fixtures: &[Fixture]) -> Result<String, Box<dyn Error>> {
    let accessors = util::by_aggregate_sorted(fixtures, "Accessor", "order");
    let mut out = String::new();
    for (idx, row) in accessors.iter().enumerate() {
        if idx > 0 {
            out.push('\n');
        }
        out.push_str(&emit_accessor(row)?);
    }
    Ok(out)
}

/// Emit one `pub fn <name>(<receiver>[, <arg>]) -> <ret> { … }` method.
/// The body is a single line picked by `accessor_kind`. Indentation is
/// 4 spaces (inside `impl Repository {`).
fn emit_accessor(row: &Fixture) -> Result<String, Box<dyn Error>> {
    let name = util::attr(row, "name");
    let receiver = util::attr(row, "receiver");
    let arg = util::attr(row, "arg");
    let ret = util::attr(row, "ret");
    let kind = util::attr(row, "accessor_kind");

    let body = match kind {
        "value_get" => "self.store.get(id)".to_string(),
        "value_get_mut" => "self.store.get_mut(id)".to_string(),
        "values_collect" => "self.store.values().collect()".to_string(),
        "len" => "self.store.len()".to_string(),
        other => return Err(format!("unknown accessor_kind: {}", other).into()),
    };

    let signature = if arg.is_empty() {
        format!("    pub fn {}({}) -> {} {{\n", name, receiver, ret)
    } else {
        format!(
            "    pub fn {}({}, {}) -> {} {{\n",
            name, receiver, arg, ret
        )
    };

    Ok(format!("{}        {}\n    }}\n", signature, body))
}
