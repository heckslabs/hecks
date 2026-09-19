// Exemplar shapes for rust/project/registry.rb's `emit_query_table` —
// see mod.rs's own header. `QueryDef`/`QueryCondition`/`QueryConditionValue`
// are real kernel types (`rust/src/kernel/named_query.rs`); `QueryComparator`
// is the same closed, eight-variant enum the ad hoc filter step already
// dispatches on (`rust/src/kernel/query_comparators.rs`). `QueryDef`'s own
// `order_by`/`limit` (added 2026-08-11) are `crate::kernel::query_ordering::
// OrderBy`/`Limit` — the same shared type `read_models.rs`'s own
// `ReadModelDef` reaches through the `read_model::ReadModelOrderBy`/
// `ReadModelLimit` aliases (kernel/read_model.rs); this file spells the
// canonical path directly since `QueryDef` has no read-model alias to go
// through. `offset` (Phase 10, equivalence-gap plan) is `query_ordering::
// Offset`, a bare `pub type Offset = Limit` — same reasoning, one more
// field reusing the identical shared type rather than a new one; a
// declared read model still has no `offset` field at all.
#![allow(dead_code, unused_variables)]

// `const` context can't call a non-`const` function — the same reason
// `policy_table`/`process_manager_table` (reactions.rs) bake a real struct
// literal here rather than a placeholder function call: `QueryDef { ... }`
// is exactly as const-evaluable as `PolicyRule { ... }` already is, so the
// placeholder row is a real literal, substituted wholesale (the same
// flush-left "one row, one item" convention those two tables already use).
// Tmpl:query_table begin
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
// Tmpl:query_table end
