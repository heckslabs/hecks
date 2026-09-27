// Exemplar shapes for rust/project/mutations.rb; see mod.rs.
// Hosts take `record: &mut Tmpl...`, not `&mut self`, as the generated mutation closures do.
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

// `remove:` on an entity list matches on the entity's identity field, not whole-element
// equality; `retain` keeps every element whose identity differs from the offered value.
struct TmplRemoveElement {
    tmpl_id_field: i64,
}
struct TmplRemoveHost {
    tmpl_field: Vec<TmplRemoveElement>,
}
fn tmpl_remove_match_placeholder() -> i64 {
    0
}
fn tmpl_mutation_remove_host(record: &mut TmplRemoveHost) {
    // TMPL:mutation_remove BEGIN
    record.tmpl_field.retain(|item| item.tmpl_id_field != tmpl_remove_match_placeholder());
    // TMPL:mutation_remove END
}
