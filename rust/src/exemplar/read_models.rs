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
    reference_name: "tmpl_reference_name",
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
},
];
// TMPL:read_model_table END
