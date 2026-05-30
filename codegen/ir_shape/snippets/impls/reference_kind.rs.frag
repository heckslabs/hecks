    /// Canonical keyword string for round-trip / serialization. Mirrors
    /// BlockParser::name pattern — each variant carries the DSL keyword
    /// that authored it, so dump.rs / canonical_ir.rb can emit the
    /// authored intent rather than a Rust-internal enum tag.
    pub fn as_str(&self) -> &'static str {
        match self {
            ReferenceKind::BelongsTo => "belongs_to",
            ReferenceKind::HasOne => "has_one",
            ReferenceKind::HasMany => "has_many",
            ReferenceKind::LegacyReferenceTo => "reference_to",
        }
    }
