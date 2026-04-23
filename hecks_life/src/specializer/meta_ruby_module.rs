//! Rust port of `lib/hecks_specializer/meta_ruby_module.rb` — the
//! fifth meta-specializer, Phase D D3. Emits a top-level loader-module
//! Ruby source file from RubyModule + ModuleConstant + ModuleClassMethod
//! + InnerModule fixture rows. Pilot target: `lib/hecks_specializer.rb`,
//! the loader every specializer target registers against.
//!
//! Emission pipeline (verbatim concatenation, mirrors the Ruby side):
//!
//!   1. doc_snippet verbatim  + blank line
//!   2. outer_requires as `require "X"\n` lines + blank line
//!   3. `module Hecks\n  module Specializer\n`
//!   4. module-level constants (with optional pre-constant doc, blank
//!      line before a doc-bearing constant when not the first)
//!   5. `class << self` block (6-space indent inside, blank-separated
//!      methods, optional pre-method doc comments)
//!   6. inner modules (with pre-module doc, verbatim methods_block_snippet
//!      inside, 4-space indent module/end)
//!   7. module close (`  end\nend\n`)
//!   8. optional autoload block: blank + autoload_doc + `Dir[...]` loop
//!
//! Ruby-emitting specializer. `.rb.frag` snippets are raw method bodies
//! with no `//` header; every read uses `util::read_snippet_raw` rather
//! than `read_snippet_body`. Split layout: this file owns orchestration
//! + `pick_module` / `constant_indent`; `meta_ruby_module_sections.rs`
//! owns the eight section emitters.
//!
//! Usage:
//!   let ruby = meta_ruby_module::emit(repo_root)?;
//!   print!("{}", ruby);
//!
//! [antibody-exempt: hecks_life/src/specializer/meta_ruby_module.rs —
//!  Phase D D3 — Ruby-native specializer port]

use crate::ir::Fixture;
use crate::specializer::meta_ruby_module_sections as sec;
use crate::specializer::util;
use std::error::Error;
use std::path::Path;

const SHAPE_REL: &str =
    "hecks_conception/capabilities/ruby_module_shape/fixtures/ruby_module_shape.fixtures";

pub fn emit(repo_root: &Path) -> Result<String, Box<dyn Error>> {
    emit_for(repo_root, None)
}

/// Pick a specific RubyModule row by `name` attribute. `None` picks
/// the first row — matches the Ruby default (`self.target_module_name`
/// = nil in the base class). Kept public-crate for future sibling
/// ports that override `target_module_name` Ruby-side.
#[allow(dead_code)]
pub fn emit_for(
    repo_root: &Path,
    target_module_name: Option<&str>,
) -> Result<String, Box<dyn Error>> {
    let shape = repo_root.join(SHAPE_REL);
    let fixtures = util::load_fixtures(&shape)?;
    let module = pick_module(&fixtures, target_module_name)?;
    let indent = constant_indent(module);

    let mut out = String::new();
    out.push_str(&sec::emit_doc(repo_root, module)?);
    out.push_str(&sec::emit_outer_requires(module));
    out.push_str(&sec::emit_module_open(module));
    out.push_str(&sec::emit_outer_constants(repo_root, &fixtures, module, &indent)?);
    out.push_str(&sec::emit_class_methods_block(repo_root, &fixtures, module, &indent)?);
    out.push_str(&sec::emit_inner_modules(repo_root, &fixtures, module, &indent)?);
    out.push_str(&sec::emit_module_close(module));
    out.push_str(&sec::emit_autoload_block(repo_root, module)?);
    Ok(out)
}

fn pick_module<'a>(
    fixtures: &'a [Fixture],
    target_module_name: Option<&str>,
) -> Result<&'a Fixture, Box<dyn Error>> {
    let rows = util::by_aggregate(fixtures, "RubyModule");
    let row = match target_module_name {
        Some(name) => rows.into_iter().find(|r| util::attr(r, "name") == name),
        None => rows.into_iter().next(),
    };
    row.ok_or_else(|| {
        format!(
            "no RubyModule row matching {:?}",
            target_module_name.unwrap_or("<first>")
        )
        .into()
    })
}

fn constant_indent(module: &Fixture) -> String {
    "  ".repeat(util::attr(module, "name").split("::").count())
}
