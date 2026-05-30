    /// Multiplicity range. Defaults to Cardinality { min: 0, max: Some(1) }
    /// for `reference_to(X)` / has_one / belongs_to ; `has_many` produces
    /// Cardinality { min: 0, max: None } (unbounded) or { min: 0, max: Some(N) }
    /// when the DSL passes `max: N`. See Reference::single / belongs_to /
    /// has_one / many / many_with_max constructors for the canonical builders.
