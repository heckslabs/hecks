//! Rust-native specializer for `storehouse/src/conception_kernel/sample.rs`.
//!
//! Data-driven projection of the conception's `SampleValueRule` catalog
//! (behaviors_conception.bluebook). Reads the type->literal rows from
//! `conception_kernel_sample_shape.fixtures` and GENERATES one match arm per
//! row, then a fixed catch-all arm (the `"sample_<lowercased>"` default, which
//! is logic, not data). This is the conception's named "simplest proof that the
//! DATA layer is real and projectable today" — and it is NOT section-as-snippet:
//! the arms are synthesized from data, capturing the type->literal knowledge.
//!
//! Each row emits `    {type_name:?} => {sample:?}.into(),` ; the `{:?}` on the
//! sample string re-escapes it, so Boolean's `"true"` round-trips to
//! `"\"true\"".into()` byte-identically.
//!
//! Usage :
//!   let rust = conception_kernel::sample::emit(repo_root)?;

use crate::specializer::util;
use std::error::Error;
use std::path::Path;

const SHAPE_REL: &str =
    "codegen/conception_kernel_sample_shape/fixtures/conception_kernel_sample_shape.fixtures";

pub fn emit(repo_root: &Path) -> Result<String, Box<dyn Error>> {
    let shape = repo_root.join(SHAPE_REL);
    let fixtures = util::load_fixtures(&shape)?;
    let rules = util::by_aggregate(&fixtures, "SampleValueRule");

    let mut out = String::new();
    out.push_str(HEADER);
    for r in &rules {
        let type_name = util::attr(r, "type_name");
        let sample = util::attr(r, "sample");
        out.push_str(&format!("        {:?} => {:?}.into(),\n", type_name, sample));
    }
    out.push_str(FOOTER);
    Ok(out)
}

const HEADER: &str = r#"//! conception_kernel::sample — the SampleValueRule table as DATA.
//!
//! How a type becomes a placeholder literal in synthesized input, setup
//! kwargs, and expect. Pure lookup — a flat table, no algorithm. This is the
//! conception's `SampleValueRule` aggregate (behaviors_conception.bluebook),
//! and the simplest proof that the DATA layer is real and projectable today:
//! the kernel owns it, and `generator.rs` delegates here until it is deleted
//! at the final gate.
//!
//!   Integer -> 1   Float -> 1.0   Boolean -> "true"   String -> "sample"
//!   <VO>    -> "sample_<lowercased type>"   (the catch-all)
//!
//! Usage:
//!   let lit = conception_kernel::sample::sample_value("Integer"); // "1"

/// Resolve an IR attribute type to the sample literal the runtime would store.
/// A verbatim port of generator.rs's `sample_value` — byte-identical output.
pub fn sample_value(t: &str) -> String {
    match t {
"#;

const FOOTER: &str = r#"        _ => format!("\"sample_{}\"", t.to_lowercase()),
    }
}
"#;
