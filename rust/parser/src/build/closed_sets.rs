//! Mirrors `AttributeCollector#synthesise_closed_set` — an inline
//! `attribute :status, one_of("open", "shut")` desugars to a value object
//! named `Naming.pascal(attribute_name)`, with one `value: String`
//! attribute and one member per listed value, `closed_set: true`. Also
//! covers `one_of do member ... end` (the standalone, named form) and
//! `member`'s own pairs-row capture (`PairsShape::verbatim` — each
//! member's fields are an open map, never resolved against a fixed
//! schema).

#[cfg(test)]
mod tests {
    // Stage 2+, once parse/value_object.rs calls into this module for
    // real.
}
