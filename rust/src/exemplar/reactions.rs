// EXEMPLAR shapes for rust/project/reactions.rb — see mod.rs's own
// header. `tmpl_body_placeholder()` gives the literal-fn shape's body a
// real, `tmpl_`-prefixed, `Json`-returning expression to substitute —
// deliberately not a bare `crate::kernel::Json::Null` marker, since a
// marker with no `tmpl_`/`Tmpl`/`TMPL_` token in it can't be caught by
// `Exemplar::LEFTOVER_PLACEHOLDER` if a caller ever forgets to supply it.
#![allow(dead_code, unused_variables)]

fn tmpl_body_placeholder() -> crate::kernel::Json {
    crate::kernel::Json::Null
}

fn tmpl_with_value_literal_fn_host() {
    // TMPL:with_value_literal_fn BEGIN
    fn tmpl_literal_fn() -> crate::kernel::Json { tmpl_body_placeholder() }
    // TMPL:with_value_literal_fn END
}

// `const` context can't call a non-`const` function (the function-call
// placeholder idiom every OTHER shape in this tree uses would refuse to
// compile here) — real `PolicyRule`/`ProcessManagerDef` rows are struct
// LITERALS, which const evaluation allows directly, so the placeholder
// is a real literal too, substituted wholesale the same way `TmplRow {
// ... }` (json.rs's `closed_set_table_row_field`) already is.
// TMPL:policy_table BEGIN
pub const POLICIES: &[crate::kernel::PolicyRule] = &[
crate::kernel::PolicyRule { policy_name: "tmpl_policy_name", event_name: "tmpl_event_name", event_qualifier: None, target_verb: "tmpl_target_verb", for_each: None, for_each_key: None, with_spec: &[] },
];
// TMPL:policy_table END

// A policy's cross-domain twin (`CrossDomainPolicyRule`, orchestrate.rs's
// own header on why this is a SEPARATE table rather than one more
// PolicyRule variant: matching it is identical, but nothing here can
// dispatch it — kernel::cli::run carries a match out as a
// `PendingCrossDomainReaction` instead, for rust/host's
// `lambda_client.rs` to actually deliver). Same "literal, not a function
// call" reasoning as `policy_table` above — `const` context.
// TMPL:cross_domain_policy_table BEGIN
pub const CROSS_DOMAIN_POLICIES: &[crate::kernel::CrossDomainPolicyRule] = &[
crate::kernel::CrossDomainPolicyRule { policy_name: "tmpl_policy_name", event_name: "tmpl_event_name", event_qualifier: None, target_domain: "tmpl_target_domain", target_verb: "tmpl_target_verb" },
];
// TMPL:cross_domain_policy_table END

// `literal_fns` (the marker's own default, `fn tmpl_literal_fns_placeholder
// () {}`) is a real module-level ITEM, not a statement — module scope
// only allows item declarations, so a bare function CALL there (what an
// earlier draft of this shape had) doesn't compile at all. Real
// `literal_fns` content is the same shape: zero or more `fn` item
// definitions, joined by blank lines, which is exactly what this marker
// gets wholesale-replaced with (possibly empty, when a process manager's
// own `with:` bindings are all bare Symbol references).
// TMPL:process_manager_table BEGIN
fn tmpl_literal_fns_placeholder() {}

pub const PROCESS_MANAGERS: &[crate::kernel::ProcessManagerDef] = &[
    crate::kernel::ProcessManagerDef { name: "tmpl_pm_name", correlates_by: "tmpl_correlates_by", starts_on: "tmpl_starts_on", ends_on: "tmpl_ends_on", initial_state: "tmpl_initial_state", handlers: &[] },
];
// TMPL:process_manager_table END

// TMPL:reference_key_table BEGIN
pub fn reference_key_for_aggregate(qualified_name: &str) -> Option<&'static str> {
    match qualified_name {
"tmpl_qualified" => Some("tmpl_key"),
        _ => None,
    }
}
// TMPL:reference_key_table END
