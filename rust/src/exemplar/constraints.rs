// EXEMPLAR shapes for rust/project/constraints.rb — see mod.rs's own
// header. Both shapes here are single-line `if ... { return Err(...); }`
// checks, spliced verbatim into a caller's own `check_invariants` body
// (types.rb) or argument-coercion block (commands.rb) — the host
// functions below exist purely to give them a real `Result`-returning
// context with a real scalar in scope, matching how they're actually
// used everywhere in generated output.
//
// These two shapes are the direct Rust reading of `ShapeField.admits`
// and `ShapeField.pattern` (`shape.bluebook`) — the two OPTIONAL,
// free-text constraint fields the language lets a field declare beside
// its `type`/`list`/`optional`. `admits_check` is `admits`; `pattern_check`
// is `pattern`. Neither is a fact this file invents a name for.
#![allow(dead_code, unused_variables)]

fn tmpl_admits_check_host(tmpl_scalar: String) -> Result<(), crate::kernel::Refusal> {
    // TMPL:admits_check BEGIN
    if !["tmpl_member_a", "tmpl_member_b"].contains(&tmpl_scalar.as_str()) { return Err(crate::kernel::Refusal::InvariantViolation(format!("{}{:?}", "tmpl_prefix_text", tmpl_scalar))); }
    // TMPL:admits_check END
    Ok(())
}

fn tmpl_pattern_check_host(tmpl_scalar: String) -> Result<(), crate::kernel::Refusal> {
    // TMPL:pattern_check BEGIN
    if !crate::kernel::pattern::matches("tmpl_pattern_text", &tmpl_scalar) { return Err(crate::kernel::Refusal::TypeMismatch(format!("{}{:?}", "tmpl_prefix_text", tmpl_scalar))); }
    // TMPL:pattern_check END
    Ok(())
}
