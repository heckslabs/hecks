//! Rust port of `lib/hecks_specializer/meta_diagnostic_validator.rb`.
//!
//! Emits `lib/hecks_specializer/diagnostic_validator.rb` byte-identical
//! to the Ruby specializer's output. This is a Ruby-emitting
//! specializer (not a Rust-emitting one): method bodies come from
//! `.rb.frag` snippets read VERBATIM (no leading `//`-comment strip —
//! Ruby bodies don't carry those headers), and the emission pipeline
//! assembles a full Ruby class file from RubyClass + RubyMethod (+
//! optional RubyConstant) rows.
//!
//! Emission pipeline (mirrors the Ruby `emit`):
//!   1. doc block (from RubyClass.doc_snippet, verbatim) + trailing "\n"
//!   2. require_relative lines (from RubyClass.requires) + trailing "\n"
//!   3. module nesting open (from RubyClass.module_path)
//!   4. class header + include mixins
//!   5. constants (if any), sorted by order; preceded by blank line
//!      when the class has includes (so the block breathes off them)
//!   6. public methods, sorted by order (blank-line between each)
//!   7. blank line + "private" + blank line + private methods
//!   8. class close + optional `register` line + module closes
//!
//! Default target row is `DiagnosticValidator` — the PC-2 pilot and
//! the tracked golden. PC-4 adds `meta_diagnostic_validator` /
//! `meta_validator_warnings` subclass-style emission via a different
//! row name, but the Rust-side Phase D port only needs the default
//! behavior to drive the tracked file regeneration.
//!
//! Usage:
//!   let rb = meta_diagnostic_validator::emit(repo_root)?;
//!   print!("{}", rb);
//!
//! [antibody-exempt: hecks_life/src/specializer/meta_diagnostic_validator.rs
//!  — Phase D D3 Ruby-native specializer port]

use crate::ir::Fixture;
use crate::specializer::util;
use std::error::Error;
use std::path::Path;

const SHAPE_REL: &str = "hecks_conception/capabilities/diagnostic_validator_meta_shape/fixtures/diagnostic_validator_meta_shape.fixtures";

/// Default `RubyClass` row to emit for — matches the Ruby side's
/// `self.target_class_name` default on `MetaDiagnosticValidator`
/// itself (nil → first row). The tracked output at
/// `lib/hecks_specializer/diagnostic_validator.rb` is the first row's
/// rendering.
const DEFAULT_TARGET_CLASS: &str = "DiagnosticValidator";

pub fn emit(repo_root: &Path) -> Result<String, Box<dyn Error>> {
    let shape = repo_root.join(SHAPE_REL);
    let fixtures = util::load_fixtures(&shape)?;

    let klass = pick_class(&fixtures, DEFAULT_TARGET_CLASS)?;
    let class_name = util::attr(klass, "name");

    let methods: Vec<&Fixture> = util::by_aggregate_sorted(&fixtures, "RubyMethod", "order")
        .into_iter()
        .filter(|m| util::attr(m, "class_name") == class_name)
        .collect();
    let public_methods: Vec<&Fixture> = methods
        .iter()
        .copied()
        .filter(|m| util::attr(m, "visibility") == "public")
        .collect();
    let private_methods: Vec<&Fixture> = methods
        .iter()
        .copied()
        .filter(|m| util::attr(m, "visibility") == "private")
        .collect();

    let mut out = String::new();
    out.push_str(&emit_doc(repo_root, klass)?);
    out.push_str(&emit_requires(klass));
    out.push_str(&emit_module_open(klass));
    out.push_str(&emit_class_header(klass));
    out.push_str(&emit_constants(repo_root, &fixtures, klass)?);
    out.push_str(&emit_methods(repo_root, &public_methods, true)?);
    out.push_str(&emit_private_section(repo_root, &private_methods)?);
    out.push_str(&emit_module_close(klass));
    Ok(out)
}

fn pick_class<'a>(fixtures: &'a [Fixture], name: &str) -> Result<&'a Fixture, Box<dyn Error>> {
    let rows = util::by_aggregate(fixtures, "RubyClass");
    rows.into_iter()
        .find(|r| util::attr(r, "name") == name)
        .ok_or_else(|| format!("no RubyClass row matching {:?}", name).into())
}

fn emit_doc(repo_root: &Path, klass: &Fixture) -> Result<String, Box<dyn Error>> {
    // Doc snippet ends with `\n`; add one more for blank-line separator
    // before the module nesting begins.
    let path = repo_root.join(util::attr(klass, "doc_snippet"));
    let raw = util::read_snippet_raw(&path)?;
    Ok(format!("{raw}\n"))
}

fn emit_requires(klass: &Fixture) -> String {
    let raw = util::attr(klass, "requires");
    if raw.is_empty() {
        return String::new();
    }
    let paths: Vec<&str> = raw.split(',').map(|p| p.trim()).filter(|p| !p.is_empty()).collect();
    if paths.is_empty() {
        return String::new();
    }
    let mut out = String::new();
    for p in &paths {
        out.push_str(&format!("require_relative \"{p}\"\n"));
    }
    out.push('\n');
    out
}

fn emit_module_open(klass: &Fixture) -> String {
    let path = util::attr(klass, "module_path");
    if path.is_empty() {
        return String::new();
    }
    let mut out = String::new();
    for (i, seg) in path.split("::").enumerate() {
        let indent = "  ".repeat(i);
        out.push_str(&format!("{indent}module {seg}\n"));
    }
    out
}

fn emit_module_close(klass: &Fixture) -> String {
    let path = util::attr(klass, "module_path");
    let depth = if path.is_empty() { 0 } else { path.split("::").count() };
    let class_end = format!("{}end\n", "  ".repeat(depth));
    let register = emit_register_line(klass, depth);
    let mut module_ends = String::new();
    for i in (0..depth).rev() {
        module_ends.push_str(&format!("{}end\n", "  ".repeat(i)));
    }
    format!("{class_end}{register}{module_ends}")
}

fn emit_register_line(klass: &Fixture, depth: usize) -> String {
    let name = util::attr(klass, "register_target_name");
    if name.is_empty() {
        return String::new();
    }
    let indent = "  ".repeat(depth);
    let class_name = util::attr(klass, "name");
    format!("\n{indent}register :{name}, {class_name}\n")
}

fn emit_class_header(klass: &Fixture) -> String {
    let module_path = util::attr(klass, "module_path");
    let depth = if module_path.is_empty() { 0 } else { module_path.split("::").count() };
    let indent = "  ".repeat(depth);
    let name = util::attr(klass, "name");
    let base = util::attr(klass, "base_class");
    let class_line = if base.is_empty() {
        format!("{indent}class {name}\n")
    } else {
        format!("{indent}class {name} < {base}\n")
    };
    let mixin_lines: String = util::attr(klass, "includes")
        .split(',')
        .map(|m| m.trim())
        .filter(|m| !m.is_empty())
        .map(|m| format!("{indent}  include {m}\n"))
        .collect();
    format!("{class_line}{mixin_lines}")
}

fn emit_constants(
    repo_root: &Path,
    fixtures: &[Fixture],
    klass: &Fixture,
) -> Result<String, Box<dyn Error>> {
    let _ = repo_root;
    let class_name = util::attr(klass, "name");
    let constants: Vec<&Fixture> = util::by_aggregate_sorted(fixtures, "RubyConstant", "order")
        .into_iter()
        .filter(|c| util::attr(c, "class_name") == class_name)
        .collect();
    if constants.is_empty() {
        return Ok(String::new());
    }
    let module_path = util::attr(klass, "module_path");
    let depth = if module_path.is_empty() { 0 } else { module_path.split("::").count() };
    let indent = "  ".repeat(depth + 1);
    let mut lines = String::new();
    for c in &constants {
        let cname = util::attr(c, "name");
        let val = util::attr(c, "value_expr");
        lines.push_str(&format!("{indent}{cname} = {val}\n"));
    }
    let includes = util::attr(klass, "includes").trim();
    Ok(if includes.is_empty() {
        lines
    } else {
        format!("\n{lines}")
    })
}

fn emit_methods(
    repo_root: &Path,
    methods: &[&Fixture],
    blank_before_first: bool,
) -> Result<String, Box<dyn Error>> {
    let mut out = String::new();
    for (i, m) in methods.iter().enumerate() {
        let lead = if i == 0 && !blank_before_first { "" } else { "\n" };
        out.push_str(lead);
        out.push_str(&emit_method(repo_root, m)?);
    }
    Ok(out)
}

fn emit_private_section(
    repo_root: &Path,
    private_methods: &[&Fixture],
) -> Result<String, Box<dyn Error>> {
    if private_methods.is_empty() {
        return Ok(String::new());
    }
    // 3 levels of 2-space indent = 6 spaces (module → module → class).
    let indent = "      ";
    let body = emit_methods(repo_root, private_methods, true)?;
    Ok(format!("\n{indent}private\n{body}"))
}

fn emit_method(repo_root: &Path, method: &Fixture) -> Result<String, Box<dyn Error>> {
    let indent = "      "; // 6 spaces: module → module → class
    let prefix = if util::attr(method, "receiver") == "self" {
        "def self."
    } else {
        "def "
    };
    let name = util::attr(method, "name");
    let signature = util::attr(method, "signature");
    let sig = if signature.is_empty() {
        format!("{prefix}{name}")
    } else {
        format!("{prefix}{name}({signature})")
    };
    let body_path = repo_root.join(util::attr(method, "body_snippet"));
    let body = util::read_snippet_raw(&body_path)?;
    let doc = emit_method_doc(repo_root, method)?;
    Ok(format!("{doc}{indent}{sig}\n{body}{indent}end\n"))
}

fn emit_method_doc(repo_root: &Path, method: &Fixture) -> Result<String, Box<dyn Error>> {
    let path = util::attr(method, "doc_snippet");
    if path.is_empty() {
        return Ok(String::new());
    }
    util::read_snippet_raw(&repo_root.join(path))
}
