    /// Which DSL keyword produced this Reference. Preserves authored
    /// intent (has_one vs belongs_to vs has_many vs reference_to) past
    /// parsing ; round-trips via ReferenceKind::as_str into the
    /// canonical IR dump.
