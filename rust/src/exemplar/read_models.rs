// EXEMPLAR shapes for rust/project/read_models.rb's `emit_read_model_table`
// — see mod.rs's own header. `ReadModelDef`/`ReadModelHead`/
// `ReferenceField` are real kernel types (`rust/src/kernel/read_model.rs`).
#![allow(dead_code, unused_variables)]

// `const` context can't call a non-`const` function — the same reason
// `queries.rs`'s own `QUERIES` table bakes a real struct literal here
// rather than a placeholder function call: `ReadModelDef { ... }` is
// exactly as const-evaluable as `QueryDef { ... }` already is, so the
// placeholder row IS a real literal, substituted wholesale.
// TMPL:read_model_table BEGIN
pub const READ_MODELS: &[crate::kernel::read_model::ReadModelDef] = &[
crate::kernel::read_model::ReadModelDef {
    verb: "tmpl_verb",
    reference_name: Some("tmpl_reference_name"),
    heads: &[
        crate::kernel::read_model::ReadModelHead {
            aggregate: "tmpl_aggregate",
            as_name: "tmpl_as_name",
            many: true,
            is_root: false,
            reference_fields: &[
                crate::kernel::read_model::ReferenceField { target_aggregate: "tmpl_target_aggregate", field: "tmpl_field" },
            ],
        },
    ],
    filtered_head: Some("tmpl_as_name"),
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
            inner_field: "tmpl_inner_field",
            inner_comparator: crate::kernel::query_comparators::QueryComparator::Eq,
            inner_value: crate::kernel::QueryConditionValue::Literal("tmpl_literal"),
        },
    ],
    order_by: Some(crate::kernel::read_model::ReadModelOrderBy { field: "tmpl_order_field", descending: true, nulls: crate::kernel::query_ordering::NullsMode::Last }),
    offset: Some(crate::kernel::read_model::ReadModelOffset::Literal(1)),
    limit: Some(crate::kernel::read_model::ReadModelLimit::Literal(5)),
    authorization: Some(crate::kernel::named_query::TenantAuth { query_name: "tmpl_query_name", tenant_field: "tmpl_tenant_field", policy: "tmpl_policy" }),
    group_by: None,
    count: false,
    median_field: None,
},
];
// TMPL:read_model_table END
