/// Multiplicity bounds for a Reference. `min` is the inclusive lower
/// bound (0 for optional, 1+ for required at_least). `max` is the
/// inclusive upper bound when Some, or `None` for unbounded collections.
///
/// Defaults per DSL keyword :
///   reference_to / has_one / belongs_to → { min: 0, max: Some(1) }
///   has_many                            → { min: 0, max: None }
///   has_many _, max: N                  → { min: 0, max: Some(N) }
///   has_many _, at_least: K, max: N     → { min: K, max: Some(N) }
///
/// Mirrors Ruby's Reference#cardinality { min:, max: } hash shape so
/// the parity contract dumps byte-identically across both parsers.
