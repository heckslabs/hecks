// EXEMPLAR shapes for rust/project/registry.rb's `emit_query_table` —
// see mod.rs's own header. `QueryDef`/`QueryCondition`/`QueryConditionValue`
// are real kernel types (`rust/src/kernel/named_query.rs`); `QueryComparator`
// is the same closed, eight-variant enum the ad hoc filter step already
// dispatches on (`rust/src/kernel/query_comparators.rs`).
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
},
];
// TMPL:query_table END
