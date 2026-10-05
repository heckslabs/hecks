// Exemplar shapes that rust/codegen/src/reactions.rs slices into generated tables;
// see mod.rs for how they are used.
#![allow(dead_code, unused_variables)]

// Carries a `tmpl_` token so Exemplar::LEFTOVER_PLACEHOLDER catches it if a
// caller forgets to substitute it.
fn tmpl_body_placeholder() -> crate::kernel::Json {
    crate::kernel::Json::Null
}

fn tmpl_with_value_literal_fn_host() {
    // TMPL:with_value_literal_fn BEGIN
    fn tmpl_literal_fn() -> crate::kernel::Json { tmpl_body_placeholder() }
    // TMPL:with_value_literal_fn END
}

// Literal rows, not a call: `const` context cannot call a non-`const` function.
// TMPL:policy_table BEGIN
pub const POLICIES: &[crate::kernel::PolicyRule] = &[
crate::kernel::PolicyRule { policy_name: "tmpl_policy_name", event_name: "tmpl_event_name", event_qualifier: None, target_verb: "tmpl_target_verb", for_each: None, for_each_key: None, with_spec: &[], where_expr: None },
];
// TMPL:policy_table END

// Separate table: nothing here can dispatch a match; rust/host delivers it.
// Literal rows for the same `const` reason as `policy_table`.
// TMPL:cross_domain_policy_table BEGIN
pub const CROSS_DOMAIN_POLICIES: &[crate::kernel::CrossDomainPolicyRule] = &[
crate::kernel::CrossDomainPolicyRule { policy_name: "tmpl_policy_name", event_name: "tmpl_event_name", event_qualifier: None, target_domain: "tmpl_target_domain", target_verb: "tmpl_target_verb", where_expr: None },
];
// TMPL:cross_domain_policy_table END

// Module scope allows only items, so `literal_fns` is zero or more `fn` items, never a call.
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

// Read by orchestrate.rs `split_routed_args`.
// TMPL:creates_table BEGIN
pub fn command_creates(verb: &str) -> bool {
    match verb {
"tmpl_verb" => true,
        _ => false,
    }
}
// TMPL:creates_table END

// Read by orchestrate.rs `split_routed_args`.
// TMPL:identity_head_table BEGIN
pub fn identity_head_for_aggregate(qualified_name: &str) -> Option<&'static str> {
    match qualified_name {
"tmpl_qualified" => Some("tmpl_head"),
        _ => None,
    }
}
// TMPL:identity_head_table END

// Keyed by "Domain::Aggregate.Entity"; entities nested two levels deep never resolve here.
// TMPL:entity_identity_head_table BEGIN
pub fn entity_identity_head_for_path(qualified_path: &str) -> Option<&'static str> {
    match qualified_path {
"tmpl_qualified" => Some("tmpl_head"),
        _ => None,
    }
}
// TMPL:entity_identity_head_table END

// Read by orchestrate.rs `split_routed_args`.
// TMPL:command_attributes_table BEGIN
pub fn command_attributes_for_verb(verb: &str) -> &'static [&'static str] {
    match verb {
"tmpl_verb" => &["tmpl_attr"],
        _ => &[],
    }
}
// TMPL:command_attributes_table END
