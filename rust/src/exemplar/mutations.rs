// EXEMPLAR shapes for rust/project/mutations.rb — see mod.rs's own
// header. Every shape here is a single generated STATEMENT line
// (`record.field = ...;`, `record.field.push(...);`, one arithmetic
// block) — the same single-line-statement risk class as constraints.rs's
// `admits_check`/`pattern_check`, not the multi-branch structural risk
// `fielded.rs`'s match arms carried. `then_set`'s RHS-computing helpers
// (`mutation_set_rhs`, `append_field_rhs`, `arithmetic_amount_expr`,
// mutations.rb) stay plain Ruby, same scoping call as json_codec.rb's
// own scalar-accessor helpers — the structural risk lives in getting the
// STATEMENT shape right, not in which field a value came from. Every
// host below takes `record: &mut Tmpl...` as a plain parameter, not
// `&mut self` — the real generated mutation closures all operate on a
// `record` binding (`kernel::dispatch`'s own mutation closure
// signature), never `self`.
#![allow(dead_code, unused_variables)]

struct TmplElement {
    tmpl_field: i64,
}
struct TmplRecordHost {
    tmpl_field: Vec<TmplElement>,
}
fn tmpl_fields_placeholder() -> TmplElement {
    TmplElement { tmpl_field: 0 }
}
fn tmpl_mutation_append_host(record: &mut TmplRecordHost) {
    // TMPL:mutation_append BEGIN
    record.tmpl_field.push(tmpl_fields_placeholder());
    // TMPL:mutation_append END
}

struct TmplScalarHost2 {
    tmpl_field: i64,
}
fn tmpl_rhs_placeholder2() -> i64 {
    0
}
fn tmpl_mutation_set_plain_host(record: &mut TmplScalarHost2) {
    // TMPL:mutation_set_plain BEGIN
    record.tmpl_field = tmpl_rhs_placeholder2();
    // TMPL:mutation_set_plain END
}

fn tmpl_optional_rhs_placeholder() -> Option<i64> {
    None
}
fn tmpl_mutation_set_unwrap_or_default_host(record: &mut TmplScalarHost2) {
    // TMPL:mutation_set_unwrap_or_default BEGIN
    record.tmpl_field = tmpl_optional_rhs_placeholder().unwrap_or_default();
    // TMPL:mutation_set_unwrap_or_default END
}

struct TmplOptionScalarHost {
    tmpl_field: Option<i64>,
}
fn tmpl_mutation_set_wrapped_host(record: &mut TmplOptionScalarHost) {
    // TMPL:mutation_set_wrapped BEGIN
    record.tmpl_field = Some(tmpl_rhs_placeholder2());
    // TMPL:mutation_set_wrapped END
}

struct TmplArithmeticHost {
    tmpl_field: i64,
}
fn tmpl_current_placeholder() -> i64 {
    0
}
fn tmpl_updated_placeholder() -> i64 {
    0
}
fn tmpl_mutation_arithmetic_host(record: &mut TmplArithmeticHost) {
    // TMPL:mutation_arithmetic BEGIN
    { let current = tmpl_current_placeholder(); record.tmpl_field = tmpl_updated_placeholder(); }
    // TMPL:mutation_arithmetic END
}
