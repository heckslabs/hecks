//! Rust-native specializer for `rust/src/hecksagon_ir.rs`.
//!
//! Sibling of `specializer::ir` — same Type/Field-row shape, same
//! emission strategy — but for the Hecksagon IR. Reads the
//! `hecksagon_ir_shape` fixtures and emits a byte-identical
//! hecksagon_ir.rs. Each Type row picks its strategy by `body_kind`:
//!
//!   - `struct`           — optional struct doc snippet, then
//!                          `#[derive(<derives>)]`, then `pub struct
//!                          <name> {`, then Field rows (each with an
//!                          optional 4-space-indented doc snippet) sorted
//!                          by `order`, then `}`.
//!   - `verbatim_section` — emit the body_snippet .rs.frag verbatim
//!                          (optionally preceded by a doc snippet). Holds
//!                          the file header + Hecksagon container struct,
//!                          and the 13 legacy adapter structs intact until
//!                          each migrates into the grammar.
//!
//! Unlike `ir::emit` there is NO header const — the generated file's `//!`
//! header rides inside the first verbatim section — so the whole file is
//! `sections.join("\n")`: one blank line between sections, terminating
//! after the last section's `}\n` (no trailing blank line).
//!
//! Only the 4 grammar-modelled structs (Family, FamilyField, Adapter,
//! Binding) are field-decomposed — they are what the grammar↔fixtures
//! parity test binds against. Editing the grammar regenerates the IR for
//! exactly those structs ; the rest rides the verbatim sections.
//!
//! Usage:
//!   let rust = hecksagon_ir::emit(repo_root)?;
//!   print!("{}", rust);
//!
//! [antibody-exempt: rust/src/specializer/hecksagon_ir.rs —
//!  Rust-native specializer for hecksagon_ir.rs ; mirror of
//!  specializer/ir.rs, asserts on Rust byte sequences]

use crate::ir::Fixture;
use crate::specializer::util;
use std::error::Error;
use std::path::Path;

const SHAPE_REL: &str = "codegen/hecksagon_ir_shape/fixtures/hecksagon_ir_shape.fixtures";

pub fn emit(repo_root: &Path) -> Result<String, Box<dyn Error>> {
    let shape = repo_root.join(SHAPE_REL);
    let fixtures = util::load_fixtures(&shape)?;
    let types = util::by_aggregate_sorted(&fixtures, "Type", "order");

    let mut sections: Vec<String> = Vec::new();
    for ty in &types {
        let body = match util::attr(ty, "body_kind") {
            "struct" => emit_struct(repo_root, &fixtures, ty)?,
            "verbatim_section" => emit_verbatim_section(repo_root, ty)?,
            other => return Err(format!("unknown body_kind: {}", other).into()),
        };
        sections.push(body);
    }

    Ok(sections.join("\n"))
}

/// Read an optional doc snippet — empty path returns empty string. The
/// snippet is emitted verbatim ; struct-level snippets carry no leading
/// indent and field-level snippets are already 4-space indented.
fn read_doc(repo_root: &Path, rel: &str) -> Result<String, Box<dyn Error>> {
    if rel.is_empty() {
        return Ok(String::new());
    }
    util::read_snippet_raw(&repo_root.join(rel))
}

fn emit_struct(
    repo_root: &Path,
    fixtures: &[Fixture],
    ty: &Fixture,
) -> Result<String, Box<dyn Error>> {
    let name = util::attr(ty, "name");
    let derives = util::attr(ty, "derives");
    let mut out = String::new();
    out.push_str(&read_doc(repo_root, util::attr(ty, "doc_snippet"))?);
    out.push_str(&format!("#[derive({})]\n", derives));
    out.push_str(&format!("pub struct {} {{\n", name));
    let fields: Vec<&Fixture> = util::by_aggregate_sorted(fixtures, "Field", "order")
        .into_iter()
        .filter(|f| util::attr(f, "type_name") == name)
        .collect();
    for field in fields {
        let doc_rel = util::attr(field, "doc_snippet");
        if !doc_rel.is_empty() {
            out.push_str(&read_doc(repo_root, doc_rel)?);
        }
        out.push_str(&format!(
            "    pub {}: {},\n",
            util::attr(field, "name"),
            util::attr(field, "field_type"),
        ));
    }
    out.push_str("}\n");
    Ok(out)
}

/// Emit a section verbatim from a .rs.frag — used for the file header +
/// Hecksagon container and the 13 legacy adapter structs. Optional doc
/// snippet prepended (empty for both of today's verbatim sections).
fn emit_verbatim_section(repo_root: &Path, ty: &Fixture) -> Result<String, Box<dyn Error>> {
    let body = util::read_snippet_raw(&repo_root.join(util::attr(ty, "body_snippet")))?;
    let mut out = String::new();
    out.push_str(&read_doc(repo_root, util::attr(ty, "doc_snippet"))?);
    out.push_str(&body);
    Ok(out)
}
