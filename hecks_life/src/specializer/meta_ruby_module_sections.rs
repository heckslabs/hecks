//! Section emitters for `meta_ruby_module` Phase D D3 port.
//!
//! Each `emit_*` function owns one phase of the 8-stage assembly: doc,
//! outer_requires, module_open, outer_constants, class_methods_block,
//! inner_modules, module_close, autoload_block. Split out of
//! `meta_ruby_module.rs` so both files stay under the 200-LoC cap —
//! the parent owns orchestration + the two tiny `pick_module` /
//! `constant_indent` helpers, this file owns one concern: fixture row →
//! Ruby text block.
//!
//! Every frag read here uses `util::read_snippet_raw` — `.rb.frag`
//! bodies are raw method bodies with no `//` header to strip.
//!
//! Usage:
//!   use crate::specializer::meta_ruby_module_sections as sec;
//!   out.push_str(&sec::emit_doc(root, module)?);
//!
//! [antibody-exempt: hecks_life/src/specializer/meta_ruby_module_sections.rs —
//!  Phase D D3 — Ruby-native specializer port]

use crate::ir::Fixture;
use crate::specializer::util;
use std::error::Error;
use std::path::Path;

// Doc block — read verbatim (ends with "\n"). Append one more "\n" to
// open a blank line before the requires block.
pub fn emit_doc(repo_root: &Path, module: &Fixture) -> Result<String, Box<dyn Error>> {
    let doc = util::read_snippet_raw(&repo_root.join(util::attr(module, "doc_snippet")))?;
    Ok(format!("{doc}\n"))
}

// require "X" lines, one per outer_requires entry. Empty list = no
// lines and no trailing blank.
pub fn emit_outer_requires(module: &Fixture) -> String {
    let raw = util::attr(module, "outer_requires");
    let libs: Vec<&str> = raw.split(',').map(|s| s.trim()).filter(|s| !s.is_empty()).collect();
    if libs.is_empty() {
        return String::new();
    }
    let mut out = String::new();
    for l in &libs {
        out.push_str(&format!("require \"{l}\"\n"));
    }
    out.push('\n');
    out
}

// "module Hecks\n  module Specializer\n" — nests the dotted name.
pub fn emit_module_open(module: &Fixture) -> String {
    let name = util::attr(module, "name");
    let mut out = String::new();
    for (i, seg) in name.split("::").enumerate() {
        out.push_str(&format!("{}module {seg}\n", "  ".repeat(i)));
    }
    out
}

// Module-level constants, sorted by order, indented to constant depth
// (2-space * segments). Each constant with a doc_snippet gets the doc
// read verbatim before the assignment, with a leading blank line
// UNLESS it's the first constant.
pub fn emit_outer_constants(
    repo_root: &Path,
    fixtures: &[Fixture],
    module: &Fixture,
    indent: &str,
) -> Result<String, Box<dyn Error>> {
    let name = util::attr(module, "name");
    let constants: Vec<&Fixture> = util::by_aggregate_sorted(fixtures, "ModuleConstant", "order")
        .into_iter()
        .filter(|c| util::attr(c, "module_name") == name)
        .collect();
    if constants.is_empty() {
        return Ok(String::new());
    }
    let mut out = String::new();
    for (i, c) in constants.iter().enumerate() {
        let c_name = util::attr(c, "name");
        let c_value = util::attr(c, "value_expr");
        let doc_path = util::attr(c, "doc_snippet");
        if doc_path.is_empty() {
            out.push_str(&format!("{indent}{c_name} = {c_value}\n"));
        } else {
            if i != 0 {
                out.push('\n');
            }
            out.push_str(&util::read_snippet_raw(&repo_root.join(doc_path))?);
            out.push_str(&format!("{indent}{c_name} = {c_value}\n"));
        }
    }
    Ok(out)
}

// The `class << self ... end` block. Blank line before, then
// `    class << self\n`, then each method (blank-separated) at 6-space
// indent, then `    end\n`.
pub fn emit_class_methods_block(
    repo_root: &Path,
    fixtures: &[Fixture],
    module: &Fixture,
    indent: &str,
) -> Result<String, Box<dyn Error>> {
    let name = util::attr(module, "name");
    let methods: Vec<&Fixture> = util::by_aggregate_sorted(fixtures, "ModuleClassMethod", "order")
        .into_iter()
        .filter(|m| util::attr(m, "module_name") == name)
        .collect();
    if methods.is_empty() {
        return Ok(String::new());
    }
    let mut out = String::new();
    out.push('\n');
    out.push_str(&format!("{indent}class << self\n"));
    for (i, m) in methods.iter().enumerate() {
        if i != 0 {
            out.push('\n');
        }
        out.push_str(&emit_class_method(repo_root, m, indent)?);
    }
    out.push_str(&format!("{indent}end\n"));
    Ok(out)
}

fn emit_class_method(
    repo_root: &Path,
    method: &Fixture,
    module_indent: &str,
) -> Result<String, Box<dyn Error>> {
    let def_indent = format!("{module_indent}  "); // inside class << self
    let name = util::attr(method, "name");
    let signature = util::attr(method, "signature");
    let sig = if signature.is_empty() {
        format!("def {name}")
    } else {
        format!("def {name}({signature})")
    };
    let doc_path = util::attr(method, "doc_snippet");
    let doc = if doc_path.is_empty() {
        String::new()
    } else {
        util::read_snippet_raw(&repo_root.join(doc_path))?
    };
    let body = util::read_snippet_raw(&repo_root.join(util::attr(method, "body_snippet")))?;
    Ok(format!("{doc}{def_indent}{sig}\n{body}{def_indent}end\n"))
}

// Inner mixin modules. Blank line before, then doc, then
// `    module Name\n`, then verbatim methods block, then `    end\n`.
pub fn emit_inner_modules(
    repo_root: &Path,
    fixtures: &[Fixture],
    module: &Fixture,
    indent: &str,
) -> Result<String, Box<dyn Error>> {
    let parent = util::attr(module, "name");
    let inners: Vec<&Fixture> = util::by_aggregate_sorted(fixtures, "InnerModule", "order")
        .into_iter()
        .filter(|i| util::attr(i, "parent_module") == parent)
        .collect();
    if inners.is_empty() {
        return Ok(String::new());
    }
    let mut out = String::new();
    for inner in &inners {
        let doc_path = util::attr(inner, "doc_snippet");
        let doc = if doc_path.is_empty() {
            String::new()
        } else {
            util::read_snippet_raw(&repo_root.join(doc_path))?
        };
        let inner_name = util::attr(inner, "name");
        let body =
            util::read_snippet_raw(&repo_root.join(util::attr(inner, "methods_block_snippet")))?;
        out.push_str(&format!("\n{doc}{indent}module {inner_name}\n{body}{indent}end\n"));
    }
    Ok(out)
}

// Close every module segment opened by emit_module_open, bottom-up.
pub fn emit_module_close(module: &Fixture) -> String {
    let depth = util::attr(module, "name").split("::").count();
    let mut out = String::new();
    for i in (0..depth).rev() {
        out.push_str(&format!("{}end\n", "  ".repeat(i)));
    }
    out
}

// Trailing `Dir[File.expand_path(<glob>, <base>)].sort.each` loop.
// Empty autoload_glob skips the whole block. Leading blank line
// separates from the closed module.
pub fn emit_autoload_block(repo_root: &Path, module: &Fixture) -> Result<String, Box<dyn Error>> {
    let glob = util::attr(module, "autoload_glob");
    if glob.is_empty() {
        return Ok(String::new());
    }
    let base = util::attr(module, "autoload_base");
    let doc_path = util::attr(module, "autoload_doc_snippet");
    let doc = if doc_path.is_empty() {
        String::new()
    } else {
        util::read_snippet_raw(&repo_root.join(doc_path))?
    };
    let loop_block = format!(
        "Dir[File.expand_path(\"{glob}\", {base})].sort.each do |path|\n  require path\nend\n"
    );
    Ok(format!("\n{doc}{loop_block}"))
}
