//! Mirrors a read model's `include` head gathering — pluralization,
//! dedup, and the `many:`/`as:` shape each `aggregate_heads` row carries
//! (`ReadModelBuilder#add_aggregate_head`). Also `group_by` field
//! derivation (`{field: :symbol}`, matching the builder's own native
//! shape rather than the String `Reconstruction::Shapes#group_by_field`
//! reads back — see `Assembly::Marks#group_by_field`'s own comment on
//! why both readings have to agree).

#[cfg(test)]
mod tests {
    // Stage 2+, once parse/read_model.rs calls into this module for real.
}
