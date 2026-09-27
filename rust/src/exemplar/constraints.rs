//! Exemplar shapes for rust/project/constraints.rb (see mod.rs).
//!
//! Both shapes are single-line refusal checks spliced into a `Result`-returning body.
#![allow(dead_code, unused_variables)]

fn tmpl_admits_check_host(tmpl_scalar: String) -> Result<(), crate::kernel::Refusal> {
    // TMPL:admits_check BEGIN
    if !["tmpl_member_a", "tmpl_member_b"].contains(&tmpl_scalar.as_str()) { return Err(crate::kernel::Refusal::InvariantViolation(crate::kernel::refusal_wording::InvariantViolationAdmitsDeclaredSetArgs { name: "tmpl_admits_name", admits: "tmpl_admits_target", admitted: &["tmpl_member_a", "tmpl_member_b"], offered: format!("{:?}", tmpl_scalar).as_str() }.render_args())); }
    // TMPL:admits_check END
    Ok(())
}

fn tmpl_pattern_check_host(tmpl_scalar: String) -> Result<(), crate::kernel::Refusal> {
    // TMPL:pattern_check BEGIN
    if !crate::kernel::pattern::matches("tmpl_pattern_text", &tmpl_scalar) { return Err(crate::kernel::Refusal::TypeMismatch(crate::kernel::refusal_wording::TypeMismatchPatternMismatchArgs { r#type: "tmpl_pattern_owner", field: "tmpl_pattern_field", pattern: "tmpl_pattern_text", offered: format!("{:?}", tmpl_scalar).as_str() }.render_args())); }
    // TMPL:pattern_check END
    Ok(())
}
