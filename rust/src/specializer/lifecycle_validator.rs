//! Rust-native specializer for `rust/src/lifecycle_validator.rs`.
//!
//! i147 Wave 9-C target — the lifecycle DiagnosticValidator, regenerated
//! from the `lifecycle_validator_shape` bluebook + DiagnosticValidator
//! / DiagnosticHelper rows + per-helper `.rs.frag` snippets at
//! codegen/lifecycle_validator_shape/.
//!
//! [antibody-exempt: rust/src/specializer/lifecycle_validator.rs —
//!  i147 Wave 9-C specializer for lifecycle_validator.rs. Kernel-surface
//!  codegen module that walks the lifecycle_validator_shape fixtures and
//!  emits the validator byte-identically. Sibling of validator.rs /
//!  validator_warnings.rs / validator_corpus.rs ; first DiagnosticValidator
//!  family member to graduate to a Rust-native specializer.]
//!
//! Walks the LifecycleValidatorShape fixtures (one DiagnosticValidator
//! row + N DiagnosticHelper rows in `order`) and assembles the file as :
//!
//!   1. doc snippet (`doc_snippet` path, read raw)
//!   2. blank line
//!   3. `pub use crate::diagnostic::{Finding, Severity};`
//!   4. extra `imports` (one per newline)
//!   5. blank line
//!   6. `Report` struct + impl block (template selected by `report_kind`)
//!   7. blank line
//!   8. rule fn (`rule_signature` { check_body_snippet })
//!   9. helpers in `order` ascending — for each : blank line, optional
//!      `doc_comment`, `signature` { body }. Empty body collapses to
//!      `{}` on the signature line (`_force_command_use` stub).
//!
//! The DiagnosticValidator + DiagnosticHelper schema is shared with
//! duplicate_policy_validator_shape ; this specializer is the first to
//! consume the schema. Future siblings (duplicate_policy, io) reuse
//! this emitter once they're scheduled.
//!
//! Usage:
//!   let rust = lifecycle_validator::emit(repo_root)?;
//!   print!("{}", rust);

use crate::ir::Fixture;
use crate::specializer::util;
use std::error::Error;
use std::path::Path;

const SHAPE_REL: &str =
    "codegen/lifecycle_validator_shape/fixtures/lifecycle_validator_shape.fixtures";

pub fn emit(repo_root: &Path) -> Result<String, Box<dyn Error>> {
    let shape = repo_root.join(SHAPE_REL);
    let fixtures = util::load_fixtures(&shape)?;

    let validator = util::by_aggregate(&fixtures, "DiagnosticValidator")
        .into_iter()
        .next()
        .ok_or("no DiagnosticValidator fixture")?;

    let module = util::attr(validator, "module");
    let helpers: Vec<&Fixture> = util::by_aggregate_sorted(&fixtures, "DiagnosticHelper", "order")
        .into_iter()
        .filter(|h| util::attr(h, "validator") == module)
        .collect();

    let mut out = String::new();

    // 1. doc snippet (verbatim)
    let doc_path = repo_root.join(util::attr(validator, "doc_snippet"));
    out.push_str(&util::read_snippet_raw(&doc_path)?);

    // 2. blank line + imports
    out.push('\n');
    out.push_str("pub use crate::diagnostic::{Finding, Severity};\n");
    for line in util::attr(validator, "imports").split('\n') {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        out.push_str(&format!("use {};\n", line));
    }
    out.push('\n');

    // 3. Report struct + impl block (selected by report_kind).
    out.push_str(report_block(util::attr(validator, "report_kind"))?);
    out.push('\n');

    // 4. Rule fn — signature { body }.
    let rule_body_path = repo_root.join(util::attr(validator, "check_body_snippet"));
    let rule_body = util::read_snippet_raw(&rule_body_path)?;
    out.push_str(util::attr(validator, "rule_signature"));
    out.push_str(" {\n");
    out.push_str(&rule_body);
    out.push_str("}\n");

    // 5. Helpers in order. Each is preceded by a blank line.
    for helper in &helpers {
        out.push('\n');
        let doc = util::attr(helper, "doc_comment");
        if !doc.is_empty() {
            out.push_str(doc);
            out.push('\n');
        }
        let signature = util::attr(helper, "signature");
        let body_path = repo_root.join(util::attr(helper, "body_snippet"));
        let body = util::read_snippet_raw(&body_path)?;
        if body.is_empty() {
            out.push_str(signature);
            out.push_str(" {}\n");
        } else {
            out.push_str(signature);
            out.push_str(" {\n");
            out.push_str(&body);
            out.push_str("}\n");
        }
    }

    Ok(out)
}

fn report_block(kind: &str) -> Result<&'static str, Box<dyn Error>> {
    match kind {
        "flat_with_strict" => Ok(REPORT_FLAT_WITH_STRICT),
        other => Err(format!("unknown report_kind: {}", other).into()),
    }
}

const REPORT_FLAT_WITH_STRICT: &str = "\
pub struct Report {
    pub findings: Vec<Finding>,
}

impl Report {
    pub fn errors(&self) -> usize {
        self.findings.iter().filter(|f| f.severity == Severity::Error).count()
    }
    pub fn warnings(&self) -> usize {
        self.findings.iter().filter(|f| f.severity == Severity::Warning).count()
    }
    pub fn passes(&self, strict: bool) -> bool {
        if self.errors() > 0 { return false; }
        if strict && self.warnings() > 0 { return false; }
        true
    }
}
";
