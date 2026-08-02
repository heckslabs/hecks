//! Every DomainRefusal wording that is not already data — `given`/`ensures`/
//! a declared `invariant` already carry their own description, read at
//! dispatch time off the command or value object that declared them. These
//! are different in kind: LANGUAGE-LEVEL refusals, the same wording for
//! every domain, not authored per-bluebook.
//!
//! Declared the same way in `Vocabulary::RefusalTemplate`
//! (language/bluebook/vocabulary.bluebook) — the Ruby twin is
//! `Hecksagain::Runtime::RefusalWording`, and spec/refusal_wording_
//! conformance_spec holds both hand-typed tables equal to the language.
//! Two templates here (`multi_field_scalar`, `composite_identity`) have no
//! Rust caller at all — Ruby's `Value.scalar`/`Value.from_identifier` have
//! no Rust equivalent, a pre-existing asymmetry this table does not paper
//! over, only names.

pub const TEMPLATES: &[(&str, &str, &str)] = &[
    ("NotFound", "creating_no_identity", "{command} creates a {aggregate} — pass {identity}:"),
    (
        "AlreadyExists",
        "creating_duplicate",
        "{command} creates a {aggregate} that already exists — {identity} {offered}",
    ),
    (
        "NotFound",
        "acting_no_identity",
        "{command} acts on an existing {aggregate} — pass {identity}:",
    ),
    ("NotFound", "record_missing", "no {aggregate} with {identity} {offered}"),
    (
        "NotFound",
        "entity_parent_no_identity",
        "{command} acts on a {aggregate}'s {entity} — pass {identity}:",
    ),
    ("UnknownVerb", "entity_unknown", "{aggregate} has no entity {entity}"),
    (
        "NotFound",
        "entity_element_no_identity",
        "{command} acts on one {entity} — pass {identity}:",
    ),
    (
        "NotFound",
        "entity_element_missing",
        "no {entity} with {identity} {wants} on {aggregate} {parent_id}",
    ),
    ("NotFound", "reference_target_missing", "no {target} with {heads} {key}"),
    (
        "NotFound",
        "read_model_reference_missing",
        "no {aggregate} with reference {offered}",
    ),
    (
        "TypeMismatch",
        "read_model_object_reference",
        "{query} refused — a reference is an id, and {field} arrived as an object",
    ),
    ("UnknownVerb", "no_query", "{aggregate} has no query {query}"),
    ("UnknownVerb", "entity_query_missing", "{entity} has no query {query}"),
    ("UnknownVerb", "entity_holds_no_list", "{aggregate} holds no list of {entity}"),
    ("UnknownVerb", "entity_no_command", "{entity} has no command {command}"),
    ("UnknownVerb", "aggregate_no_command", "{aggregate} has no command {command}"),
    ("UnknownVerb", "no_domain", "no domain {domain} loaded (verb {verb})"),
    ("UnknownVerb", "no_read_model", "{domain} has no read model {query}"),
    (
        "UnknownVerb",
        "not_fully_qualified",
        "{verb} is not a fully-qualified verb (Domain::Aggregate.Command)",
    ),
    ("UnknownVerb", "no_aggregate", "{domain} has no aggregate {aggregate}"),
    (
        "LifecycleRefused",
        "transition_blocked",
        "{command} refused — {field} is {current}, and {command} moves it only from {allowed}",
    ),
    (
        "TypeMismatch",
        "value_object_shape",
        "{name} is a {type} — pass its fields as an object, not {offered}",
    ),
    (
        "TypeMismatch",
        "reference_as_object",
        "{command} refused — a reference is an id, and {attribute} arrived as an object{known_by}",
    ),
    (
        "TypeMismatch",
        "multi_field_scalar",
        "{type} has multiple fields and cannot stand in for a scalar",
    ),
    (
        "TypeMismatch",
        "composite_identity",
        "{type} is a composite identity — an identity must have exactly one field",
    ),
    ("TypeMismatch", "numeric_field", "{type}.{field} expects {expected}, got {offered}"),
    ("TypeMismatch", "pattern_mismatch", "{type}.{field} must match {pattern}, got {offered}"),
    ("TypeMismatch", "arithmetic_amount", "{op} of {target} needs an Integer, got {offered}"),
    (
        "TypeMismatch",
        "arithmetic_current",
        "{op} of {target} needs an Integer {target}, got {offered}",
    ),
    (
        "TypeMismatch",
        "arithmetic_shared_field",
        "{op} of {target} needs a value object with one shared Integer field",
    ),
    ("UnknownArgument", "unknown_args", "{command} does not declare {unknown} — it takes {declared}"),
    ("AbsentArgument", "absent_args", "{command} was not given {absent} — it takes {declared}"),
    ("InvariantViolation", "closed_set_member", "{type} admits {admitted} — got {offered}"),
    (
        "InvariantViolation",
        "admits_declared_set",
        "{name} admits {admits} — {admitted} — got {offered}",
    ),
    (
        "InvariantViolation",
        "undeclared_set",
        "{name} admits {admits}, which this chapter does not declare — a closed set is named Aggregate::SetName, and it must be one the bluebook actually holds",
    ),
];

/// Plain text substitution, never expression syntax — a template is read,
/// not evaluated. `values` are computed by the caller (a joined list, a
/// rendered identity reading, …) exactly as Ruby's `RefusalWording.render`
/// keyword args are.
pub fn render(refusal: &str, site: &str, values: &[(&str, &str)]) -> String {
    let template = TEMPLATES
        .iter()
        .find(|(r, s, _)| *r == refusal && *s == site)
        .map(|(_, _, template)| *template)
        .unwrap_or_else(|| {
            panic!("no refusal template for {refusal}/{site} — declare it in Vocabulary::RefusalTemplate first")
        });

    values.iter().fold(template.to_string(), |text, (key, value)| {
        text.replace(&format!("{{{key}}}"), value)
    })
}
