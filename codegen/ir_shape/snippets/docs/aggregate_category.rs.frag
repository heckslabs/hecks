    /// Bluebook category — the directory grouping under
    /// `aggregates/`, e.g. "discipline", "framework", "world". Stamped
    /// from the bluebook's `category "X"` declaration at parse time
    /// and preserved through `load_combined_domain` so the FQN
    /// resolver can match `Domain::Aggregate.Command` against either
    /// the bluebook context or its category. None when the bluebook
    /// didn't declare a category. Added 2026-05-12 for the i560 FQN
    /// migration (v2 — 2-segments-plus-dot form).
