//! Mirrors `reference_to`/`has_many`/`has_one`/`belongs_to` attribute
//! minting (`attribute_collector.rb` and its `AggregateBuilder`/
//! `EntityBuilder` callers). All four FILL the same field
//! (`reference_to` — see syntax.bluebook's own comment on why
//! `has_many`/`has_one`/`belongs_to` share it): each builds one
//! `Reference`-typed attribute. `has_many`'s target is the SINGULAR of
//! what was written and mints no `_id` suffix — a Ruby-builder naming
//! default this module has to reproduce exactly, not just the edge (which
//! ATTRIBUTE gets built) a projected parser needs.

#[cfg(test)]
mod tests {
    // Stage 2+, once parse/aggregate.rs and parse/entity.rs call into
    // this module for real.
}
