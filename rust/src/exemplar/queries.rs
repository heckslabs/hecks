// EXEMPLAR shapes for rust/project/registry.rb's `emit_query_table` —
// see mod.rs's own header. `QueryDef`/`QueryCondition`/`QueryConditionValue`
// are real kernel types (`rust/src/kernel/named_query.rs`); `QueryComparator`
// is the same closed, eight-variant enum the ad hoc filter step already
// dispatches on (`rust/src/kernel/query_comparators.rs`). `QueryDef`'s own
// `order_by`/`limit` (added 2026-08-11) are `crate::kernel::query_ordering::
// OrderBy`/`Limit` — the SAME shared type `read_models.rs`'s own
// `ReadModelDef` reaches through the `read_model::ReadModelOrderBy`/
// `ReadModelLimit` aliases (kernel/read_model.rs); this file spells the
// canonical path directly since `QueryDef` has no read-model alias to go
// through.
#![allow(dead_code, unused_variables)]

// `const` context can't call a non-`const` function — the same reason
// `policy_table`/`process_manager_table` (reactions.rs) bake a real struct
// LITERAL here rather than a placeholder function call: `QueryDef { ... }`
// is exactly as const-evaluable as `PolicyRule { ... }` already is, so the
// placeholder row IS a real literal, substituted wholesale (the SAME
// flush-left "one row, one item" convention those two tables already use).
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
    order_by: Some(crate::kernel::query_ordering::OrderBy { field: "tmpl_order_field", descending: true }),
    limit: Some(crate::kernel::query_ordering::Limit::Literal(5)),
},
];
// TMPL:query_table END
