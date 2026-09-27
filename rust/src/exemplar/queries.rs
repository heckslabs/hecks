// Exemplar shape for rust/project/registry.rb's `emit_query_table`; see mod.rs.
#![allow(dead_code, unused_variables)]

// A `const` cannot call a function, so the row is a real literal substituted wholesale.
// TMPL:query_table BEGIN
pub const QUERIES: &[crate::kernel::QueryDef] = &[
crate::kernel::QueryDef {
    verb: "tmpl_verb",
    aggregate: "tmpl_aggregate",
    conditions: &[
        crate::kernel::QueryCondition {
            field: "tmpl_field",
            comparator: crate::kernel::query_comparators::QueryComparator::Eq,
            value: crate::kernel::QueryConditionValue::Literal("tmpl_literal"),
        },
    ],
    reference_hop_conditions: &[
        crate::kernel::read_model::ReferenceHopCondition {
            via_field: "tmpl_via_field",
            target_aggregate: "tmpl_target_aggregate",
            through: &[crate::kernel::read_model::HopStep { via_field: "tmpl_via_field", target_aggregate: "tmpl_target_aggregate" }],
            inner_field: "tmpl_inner_field",
            inner_comparator: crate::kernel::query_comparators::QueryComparator::Eq,
            inner_value: crate::kernel::QueryConditionValue::Literal("tmpl_literal"),
        },
    ],
    order_by: Some(crate::kernel::query_ordering::OrderBy { field: "tmpl_order_field", descending: true, nulls: crate::kernel::query_ordering::NullsMode::Last }),
    offset: Some(crate::kernel::query_ordering::Offset::Literal(1)),
    limit: Some(crate::kernel::query_ordering::Limit::Literal(5)),
    authorization: Some(crate::kernel::named_query::TenantAuth { query_name: "tmpl_query_name", tenant_field: "tmpl_tenant_field", policy: "tmpl_policy" }),
},
];
// TMPL:query_table END
