//! Rust-native specializer for `rust/src/specializer/mod.rs` itself — the
//! i650 Futamura self-application target.
//!
//! The canonical 2nd Futamura projection asks `specialize(specialize, …)` to
//! reproduce the specializer byte-for-byte. mod.rs is the natural first target :
//! its identity IS its routing — a `pub mod` list + an `emit()` dispatch table.
//! Make that routing DATA and the specializer becomes a fixed point of itself.
//!
//! Shape (mirrors `cli_dispatch_shape`) :
//!   Submodule row — one `pub mod <name>;` line. Fields : name, order.
//!   EmitArm   row — one match arm in `emit()`. Fields : target_name,
//!                   aliases (comma-separated, optional), module_path, order.
//!                   Emits `"<target>"[ | "<alias>"…] => <module_path>::emit(repo_root),`.
//!
//! The header (doc + `use`), the catch-all, and `emit_section()` ride verbatim
//! `.rs.frag` snippets — they are scaffolding, not routing. specializer_mod
//! appears in its OWN Submodule + EmitArm rows : the fixed point, self-hosted.
//!
//! Usage :
//!   let rust = specializer_mod::emit(repo_root)?;
//!   print!("{}", rust);

use crate::specializer::util;
use std::error::Error;
use std::path::Path;

const SHAPE_REL: &str =
    "codegen/specializer_mod_shape/fixtures/specializer_mod_shape.fixtures";
const HEADER_REL: &str = "codegen/specializer_mod_shape/snippets/header.rs.frag";
const EMIT_OPEN_REL: &str = "codegen/specializer_mod_shape/snippets/emit_open.rs.frag";
const TAIL_REL: &str = "codegen/specializer_mod_shape/snippets/tail.rs.frag";

pub fn emit(repo_root: &Path) -> Result<String, Box<dyn Error>> {
    let shape = repo_root.join(SHAPE_REL);
    let fixtures = util::load_fixtures(&shape)?;

    let mut out = String::new();

    // Header — doc comment + `use` lines, verbatim.
    out.push_str(&util::read_snippet_raw(&repo_root.join(HEADER_REL))?);

    // `pub mod <name>;` — one line per Submodule row, in order.
    for m in util::by_aggregate_sorted(&fixtures, "Submodule", "order") {
        out.push_str(&format!("pub mod {};\n", util::attr(m, "name")));
    }

    // emit() doc + signature + `match target {`, verbatim.
    out.push_str(&util::read_snippet_raw(&repo_root.join(EMIT_OPEN_REL))?);

    // One match arm per EmitArm row : `"<target>"[ | "<alias>"…] => <path>::emit(repo_root),`
    for a in util::by_aggregate_sorted(&fixtures, "EmitArm", "order") {
        let mut patterns = format!("\"{}\"", util::attr(a, "target_name"));
        if let Some(aliases) = util::attr_opt(a, "aliases") {
            for alias in aliases.split(',') {
                let alias = alias.trim();
                if !alias.is_empty() {
                    patterns.push_str(&format!(" | \"{}\"", alias));
                }
            }
        }
        out.push_str(&format!(
            "        {} => {}::emit(repo_root),\n",
            patterns,
            util::attr(a, "module_path"),
        ));
    }

    // Catch-all + emit() close + emit_section(), verbatim.
    out.push_str(&util::read_snippet_raw(&repo_root.join(TAIL_REL))?);

    Ok(out)
}
