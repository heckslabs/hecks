/// Which DSL keyword produced this Reference. The IR carries the
/// authored intent past parsing so projections (mermaid diagram,
/// macrophage validators) can honor the original declaration rather
/// than collapsing all forms onto a single multiplicity shape.
///
/// Variants :
///   BelongsTo          — `belongs_to X` ; dependent side, single.
///   HasOne             — `has_one X` ; owner side, single.
///   HasMany            — `has_many Xs` ; owner side, collection.
///   LegacyReferenceTo  — `reference_to(X)` ; pre-Sprint-7 unidir form,
///                          treated as BelongsTo for IR shape but kept
///                          distinct so the retire-reference-to-keyword
///                          macrophage can flag call sites.
///
/// Round-trips through `ReferenceKind::as_str()` for serde / canonical-
/// IR dump. Ruby's reference.rb mirrors via `attr_reader :kind`.
