//! Rust-native specializer for `storehouse/src/ir.rs`.
//!
//! i147 Wave 4-C target — REAL compression of the IR struct definitions.
//! Reads `Type`, `Field`, and `Variant` rows from the ir_shape fixture and
//! emits a byte-identical ir.rs. Each Type row picks its emission strategy
//! by `body_kind`:
//!
//!   - `struct` — optional doc snippet, then `#[derive(<derives>)]`, then
//!                `pub struct <name> {`, then fields (each with optional
//!                doc snippet prepended) sorted by `order`, then `}`.
//!
//!   - `enum`   — optional doc snippet, then `#[derive(<derives>)]`, then
//!                `pub enum <name> {`, then variants (each with optional
//!                doc snippet prepended) sorted by `order`, then `}`.
//!
//!   - `impl`   — optional doc snippet, then `impl <impl_target> {`, then
//!                the verbatim body snippet, then `}`. impl bodies are too
//!                bespoke to compress further ; one impl row per impl.
//!
//! Sections are joined with a single blank line ; the file terminates
//! after the last section's closing brace + newline (no trailing blank
//! line) — matching the hand-written ir.rs byte-for-byte.
//!
//! Cross-consumer impact : every other Rust-native specializer that binds
//! to ir.rs's struct field names (parser, dump, behaviors_parser,
//! hecksagon_parser, fixtures_parser) reads the SAME field knowledge
//! through this fixture. Adding a struct field is now a fixture-row edit,
//! not a Rust hand-edit + cascading specializer chase.
//!
//! Usage:
//!   let rust = ir::emit(repo_root)?;
//!   print!("{}", rust);
//!
//! [antibody-exempt: storehouse/src/specializer/ir.rs —
//!  i147 Wave 4-C — Rust-native specializer for ir.rs]

use crate::ir::Fixture;
use crate::specializer::util;
use std::error::Error;
use std::path::Path;

const SHAPE_REL: &str = "codegen/ir_shape/fixtures/ir_shape.fixtures";

pub fn emit(repo_root: &Path) -> Result<String, Box<dyn Error>> {
    let shape = repo_root.join(SHAPE_REL);
    let fixtures = util::load_fixtures(&shape)?;
    let types = util::by_aggregate_sorted(&fixtures, "Type", "order");

    let mut sections: Vec<String> = Vec::new();
    for ty in &types {
        let body = match util::attr(ty, "body_kind") {
            "struct" => emit_struct(repo_root, &fixtures, ty)?,
            "enum" => emit_enum(repo_root, &fixtures, ty)?,
            "impl" => emit_impl(repo_root, ty)?,
            "verbatim_section" => emit_verbatim_section(repo_root, ty)?,
            other => return Err(format!("unknown body_kind: {}", other).into()),
        };
        sections.push(body);
    }

    let mut out = String::new();
    out.push_str(HEADER);
    out.push_str(&sections.join("\n"));
    Ok(out)
}

const HEADER: &str = r#"//! Domain IR — the intermediate representation
//!
//! Same structure as the Ruby BluebookModel, but in Rust.
//! This is what the parser produces and the generators consume.
//!
//! [antibody-exempt: ir.rs — kernel-surface IR struct; the parser_shape
//!  specializer cannot be bootstrapped until the IR it reads also defines
//!  itself. Additions tracked here:
//!  • i106 dsl-mutation-primitives — Multiply / Clamp / Decay on MutationOp
//!    (enables pulse_organs.bluebook + consolidate.bluebook retirement)
//!  • identified-by-natural-keys — Aggregate.identified_by; subsumes
//!    unique:true singleton pattern; drives natural-key dispatch in
//!    repository.rs. Each addition enables a new .bluebook surface.]

use std::fmt;

"#;

/// Read an optional doc snippet — empty path returns empty string. The
/// snippet is emitted verbatim ; per the shape contract, struct-level
/// snippets carry no leading indent and field-level snippets are already
/// 4-space indented.
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

fn emit_enum(
    repo_root: &Path,
    fixtures: &[Fixture],
    ty: &Fixture,
) -> Result<String, Box<dyn Error>> {
    let name = util::attr(ty, "name");
    let derives = util::attr(ty, "derives");
    let mut out = String::new();
    out.push_str(&read_doc(repo_root, util::attr(ty, "doc_snippet"))?);
    out.push_str(&format!("#[derive({})]\n", derives));
    out.push_str(&format!("pub enum {} {{\n", name));
    let variants: Vec<&Fixture> = util::by_aggregate_sorted(fixtures, "Variant", "order")
        .into_iter()
        .filter(|v| util::attr(v, "type_name") == name)
        .collect();
    for variant in variants {
        let doc_rel = util::attr(variant, "doc_snippet");
        if !doc_rel.is_empty() {
            out.push_str(&read_doc(repo_root, doc_rel)?);
        }
        // Optional `body` attribute carries struct-variant payload —
        // e.g. `{ value: String }` — emitted as `Name { ... },` when
        // present. Bare variants leave `body` empty and emit `Name,`.
        let body = util::attr(variant, "body");
        if body.is_empty() {
            out.push_str(&format!("    {},\n", util::attr(variant, "name")));
        } else {
            out.push_str(&format!("    {} {},\n", util::attr(variant, "name"), body));
        }
    }
    out.push_str("}\n");
    Ok(out)
}

/// Emit a free function (or other top-level item) verbatim from a
/// snippet. Used for items that don't fit struct / enum / impl —
/// e.g. the `fn entry()` helper that constructs `BlockGrammarEntry`
/// values for the canonical_bluebook impl. body_kind: "verbatim_section"
/// with body_snippet pointing at the .rs.frag.
fn emit_verbatim_section(repo_root: &Path, ty: &Fixture) -> Result<String, Box<dyn Error>> {
    let body = util::read_snippet_raw(&repo_root.join(util::attr(ty, "body_snippet")))?;
    let mut out = String::new();
    out.push_str(&read_doc(repo_root, util::attr(ty, "doc_snippet"))?);
    out.push_str(&body);
    Ok(out)
}

fn emit_impl(repo_root: &Path, ty: &Fixture) -> Result<String, Box<dyn Error>> {
    let target = util::attr(ty, "impl_target");
    let body = util::read_snippet_raw(&repo_root.join(util::attr(ty, "body_snippet")))?;
    let mut out = String::new();
    out.push_str(&read_doc(repo_root, util::attr(ty, "doc_snippet"))?);
    out.push_str(&format!("impl {} {{\n", target));
    out.push_str(&body);
    out.push_str("}\n");
    Ok(out)
}
