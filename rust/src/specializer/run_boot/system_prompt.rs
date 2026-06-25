//! Rust-native specializer for `storehouse/src/run_boot/system_prompt.rs`.
//!
//! Emits the Phase 4 GenerateSystemPrompt runner byte-identical to the
//! tracked source. Reads `Section` rows (order, body_kind, name,
//! signature, snippet_path, doc) and `BeingVar` rows (per-being match
//! arms) from the SystemPromptAssembly fixtures and concatenates the
//! file in declared section order.
//!
//! Body kinds (one branch per row in the Section table) :
//!
//!   header_doc      — emit the named .rs.frag verbatim (raw read,
//!                      preserves leading `//!` doc comments) ; one
//!                      blank line follows so the imports block lands
//!                      separated from the doc header.
//!   imports_block   — emit the `imports` attr verbatim (one `\n`-
//!                      separated `use ...;` per line), trailing blank.
//!   embedded_fn     — emit the doc lines + signature + `{` + named
//!                      .rs.frag interpolated as the function body
//!                      (read with util::read_snippet_body, leading
//!                      comment header stripped) + `}`, blank line.
//!   being_match_fn  — same shape as embedded_fn but the body is
//!                      generated from BeingVar rows : a HashMap insert
//!                      for `being`, then a padded `match being { … }`
//!                      destructure into (born, other, boot_script),
//!                      then the three remaining inserts. Mirrors
//!                      dump.rs's enum_match padding.
//!   tests_block     — emit the `#[cfg(test)] mod tests { … }` snippet
//!                      verbatim, raw read ; the file ends here so no
//!                      trailing blank line.
//!
//! Usage:
//!   let rust = run_boot_system_prompt::emit(repo_root)?;
//!   print!("{}", rust);
//!
//! [antibody-exempt: storehouse/src/specializer/run_boot/system_prompt.rs —
//!  i146 piece 4 — Rust-native specializer for run_boot/system_prompt.rs]

use crate::ir::Fixture;
use crate::specializer::util;
use std::error::Error;
use std::path::Path;

// The specializer fixtures + snippets describe what the kernel emits ;
// they're kernel-shape, not being-shape. Per the 2026-05-08 hecks/miette
// boundary cleanup (boundary B : kernel-describing bluebooks stay in
// hecks ; being-shape bluebooks live in the being's repo), they moved
// from `../miette/self/system_prompt/system_prompt_assembly/` to
// `hecks/codegen/system_prompt_assembly_shape/` alongside the other
// specializer shapes. The earlier i117/i163 home in miette is gone.
const SHAPE_REL: &str =
    "codegen/system_prompt_assembly_shape/fixtures/system_prompt_assembly.fixtures";

pub fn emit(repo_root: &Path) -> Result<String, Box<dyn Error>> {
    let shape = repo_root.join(SHAPE_REL);
    let fixtures = util::load_fixtures(&shape)?;
    let sections = util::by_aggregate_sorted(&fixtures, "Section", "order");

    let mut out = String::new();
    for section in &sections {
        out.push_str(&emit_section(repo_root, &fixtures, section)?);
    }
    Ok(out)
}

fn emit_section(
    repo_root: &Path,
    fixtures: &[Fixture],
    section: &Fixture,
) -> Result<String, Box<dyn Error>> {
    match util::attr(section, "body_kind") {
        "header_doc" => emit_header_doc(repo_root, section),
        "imports_block" => Ok(emit_imports_block(section)),
        "embedded_fn" => emit_embedded_fn(repo_root, section),
        "being_match_fn" => Ok(emit_being_match_fn(fixtures, section)),
        "tests_block" => emit_tests_block(repo_root, section),
        other => Err(format!("unknown body_kind: {}", other).into()),
    }
}

fn emit_header_doc(repo_root: &Path, section: &Fixture) -> Result<String, Box<dyn Error>> {
    let path = repo_root.join(util::attr(section, "snippet_path"));
    let raw = util::read_snippet_raw(&path)?;
    Ok(format!("{}\n", raw))
}

fn emit_imports_block(section: &Fixture) -> String {
    let imports = util::attr(section, "imports");
    let mut out = String::new();
    for line in imports.split('\n') {
        if line.is_empty() { continue; }
        out.push_str(line);
        out.push('\n');
    }
    out.push('\n');
    out
}

fn emit_embedded_fn(repo_root: &Path, section: &Fixture) -> Result<String, Box<dyn Error>> {
    let snippet = repo_root.join(util::attr(section, "snippet_path"));
    let body = util::read_snippet_body(&snippet)?;
    let doc = util::attr(section, "doc");
    let signature = util::attr(section, "signature");
    let mut out = String::new();
    if !doc.is_empty() {
        out.push_str(doc);
        out.push('\n');
    }
    out.push_str(signature);
    out.push_str(" {\n");
    out.push_str(&body);
    out.push_str("}\n\n");
    Ok(out)
}

fn emit_tests_block(repo_root: &Path, section: &Fixture) -> Result<String, Box<dyn Error>> {
    let path = repo_root.join(util::attr(section, "snippet_path"));
    util::read_snippet_raw(&path)
}

fn emit_being_match_fn(fixtures: &[Fixture], section: &Fixture) -> String {
    let doc = util::attr(section, "doc");
    let signature = util::attr(section, "signature");

    let beings = util::by_aggregate_sorted(fixtures, "BeingVar", "order");

    // Padding rule (mirrors dump.rs's enum_match) : pad the `"<born>",`
    // column so all non-wildcard arms align on the next tuple element.
    // The `_` wildcard arm is emitted unpadded (its values come from
    // the same fixture but use a different tuple width — see snippet).
    let widest_born_quoted = beings
        .iter()
        .filter(|b| util::attr(b, "pattern") != "_")
        .map(|b| util::attr(b, "born").len() + 2)  // +2 for the surrounding quotes
        .max()
        .unwrap_or(0);

    let mut arms: Vec<String> = Vec::new();
    for b in &beings {
        let pattern = util::attr(b, "pattern");
        let born = util::attr(b, "born");
        let other = util::attr(b, "other");
        let boot_script = util::attr(b, "boot_script");
        if pattern == "_" {
            arms.push(format!(
                "        _ => (\"{}\", \"{}\", \"{}\"),",
                born, other, boot_script,
            ));
        } else {
            let born_quoted_len = born.len() + 2;
            let pad = " ".repeat(widest_born_quoted - born_quoted_len);
            arms.push(format!(
                "        {} => (\"{}\",{} \"{}\", \"{}\"),",
                pattern, born, pad, other, boot_script,
            ));
        }
    }

    let mut out = String::new();
    if !doc.is_empty() {
        out.push_str(doc);
        out.push('\n');
    }
    out.push_str(signature);
    out.push_str(" {\n");
    out.push_str("    let mut v = HashMap::new();\n");
    out.push_str("    v.insert(\"being\", being.to_string());\n");
    out.push_str("    let (born, other, boot_script) = match being {\n");
    out.push_str(&arms.join("\n"));
    out.push_str("\n    };\n");
    out.push_str("    v.insert(\"born\",        born.to_string());\n");
    out.push_str("    v.insert(\"other\",       other.to_string());\n");
    out.push_str("    v.insert(\"boot_script\", boot_script.to_string());\n");
    out.push_str("    v\n");
    out.push_str("}\n\n");
    out
}
