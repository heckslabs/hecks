//! Rust port of `lib/hecks_specializer/meta_subclass.rb`.
//!
//! Emits one thin-subclass Ruby shell under `lib/hecks_specializer/`
//! from a `SpecializerSubclass` fixture row — the Phase C PC-1 pilot,
//! now also available through the Phase D Rust-native driver.
//!
//! Unlike the D1/D2 ports, which emit Rust, this port emits Ruby.
//! The source fixtures contain no `.rb.frag` snippets — every shell
//! is assembled inline from fixture attributes (class_name,
//! base_class, module_doc, shape_path, target_rs_path, target_name,
//! output_rb). The template has to match the hand-written shells
//! byte-for-byte: doc block, `require_relative`, class body, register
//! call.
//!
//! Which row to emit is controlled by a row-target name — the
//! dispatcher picks the row whose `target_name` matches. Default
//! (`meta_subclass`) emits the DuplicatePolicy row, mirroring the
//! Ruby `MetaSubclass.row_target_name`; `meta_subclass_lifecycle`
//! picks the Lifecycle row, mirroring `MetaSubclassLifecycle`.
//!
//! Usage:
//!   let rb = meta_subclass::emit_named(repo_root, "duplicate_policy")?;
//!   print!("{}", rb);
//!
//! [antibody-exempt: hecks_life/src/specializer/meta_subclass.rs —
//!  Phase D D3 — Ruby-native specializer port]

use crate::specializer::util;
use std::error::Error;
use std::path::Path;

const SHAPE_REL: &str = "hecks_conception/capabilities/specializer/fixtures/specializer.fixtures";

/// Emit the shell for the `duplicate_policy` row — the default
/// `meta_subclass` dispatch target, mirroring Ruby
/// `MetaSubclass.row_target_name`.
pub fn emit(repo_root: &Path) -> Result<String, Box<dyn Error>> {
    emit_named(repo_root, "duplicate_policy")
}

/// Emit the shell for the `lifecycle` row — the
/// `meta_subclass_lifecycle` dispatch target, mirroring Ruby
/// `MetaSubclassLifecycle.row_target_name`.
pub fn emit_lifecycle(repo_root: &Path) -> Result<String, Box<dyn Error>> {
    emit_named(repo_root, "lifecycle")
}

/// Locate the `SpecializerSubclass` row whose `target_name` matches
/// `row_target_name`, then render the thin-subclass Ruby shell.
pub fn emit_named(repo_root: &Path, row_target_name: &str) -> Result<String, Box<dyn Error>> {
    let shape = repo_root.join(SHAPE_REL);
    let fixtures = util::load_fixtures(&shape)?;
    let rows = util::by_aggregate(&fixtures, "SpecializerSubclass");
    let row = rows
        .iter()
        .find(|r| util::attr(r, "target_name") == row_target_name)
        .ok_or_else(|| {
            format!(
                "no SpecializerSubclass row for {:?}",
                row_target_name
            )
        })?;
    Ok(emit_row(row))
}

fn emit_row(row: &crate::ir::Fixture) -> String {
    let output_rb = util::attr(row, "output_rb");
    let class_name = util::attr(row, "class_name");
    let base_class = util::attr(row, "base_class");
    let shape_path = util::attr(row, "shape_path");
    let target_rs_path = util::attr(row, "target_rs_path");
    let target_name = util::attr(row, "target_name");
    let module_doc = util::attr(row, "module_doc");

    // Ruby:
    //   doc_lines = module_doc.split("\n").map { |l| l.empty? ? "#" : "# #{l}" }
    // The fixtures parser already expanded `\n` escapes to real newlines.
    let doc_lines: Vec<String> = module_doc
        .split('\n')
        .map(|line| {
            if line.is_empty() {
                "#".to_string()
            } else {
                format!("# {line}")
            }
        })
        .collect();
    let doc_block = doc_lines.join("\n");

    // Mirrors the Ruby heredoc byte-for-byte. Indentation is two
    // spaces for `module Specializer`, four for the class body, six
    // for SHAPE/TARGET_RS.
    format!(
        "\
# {output_rb}
#
{doc_block}

require_relative \"diagnostic_validator\"

module Hecks
  module Specializer
    class {class_name} < {base_class}
      SHAPE = REPO_ROOT.join(\"{shape_path}\")
      TARGET_RS = REPO_ROOT.join(\"{target_rs_path}\")
    end

    register :{target_name}, {class_name}
  end
end
",
        output_rb = output_rb,
        doc_block = doc_block,
        class_name = class_name,
        base_class = base_class,
        shape_path = shape_path,
        target_rs_path = target_rs_path,
        target_name = target_name,
    )
}
