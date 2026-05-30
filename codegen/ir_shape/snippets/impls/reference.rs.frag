    /// Construct a single-cardinality Reference defaulting to
    /// LegacyReferenceTo — kept for existing call sites that pre-date
    /// the kind field. New code should use belongs_to() / has_one() /
    /// has_many() / many_with_max() explicitly so the authored intent
    /// rides into the IR.
    pub fn single(name: String, target: String, domain: Option<String>) -> Self {
        Reference {
            name, target, domain,
            cardinality: Cardinality { min: 0, max: Some(1) },
            kind: ReferenceKind::LegacyReferenceTo,
        }
    }

    /// Construct a Reference from `belongs_to X`. Single cardinality on
    /// the dependent side ; identity-only ; cross-aggregate.
    pub fn belongs_to(name: String, target: String, domain: Option<String>) -> Self {
        Reference {
            name, target, domain,
            cardinality: Cardinality { min: 0, max: Some(1) },
            kind: ReferenceKind::BelongsTo,
        }
    }

    /// Construct a Reference from `has_one X`. Single cardinality on
    /// the owner side ; mirrors belongs_to in shape, differs in intent.
    pub fn has_one(name: String, target: String, domain: Option<String>) -> Self {
        Reference {
            name, target, domain,
            cardinality: Cardinality { min: 0, max: Some(1) },
            kind: ReferenceKind::HasOne,
        }
    }

    /// Construct an unbounded `has_many Xs` Reference — max: None means
    /// the collection has no declared upper bound.
    pub fn many(name: String, target: String, domain: Option<String>) -> Self {
        Reference {
            name, target, domain,
            cardinality: Cardinality { min: 0, max: None },
            kind: ReferenceKind::HasMany,
        }
    }

    /// Construct a `has_many Xs, max: N` Reference — bounded collection.
    pub fn many_with_max(name: String, target: String, domain: Option<String>, max: usize) -> Self {
        Reference {
            name, target, domain,
            cardinality: Cardinality { min: 0, max: Some(max) },
            kind: ReferenceKind::HasMany,
        }
    }
