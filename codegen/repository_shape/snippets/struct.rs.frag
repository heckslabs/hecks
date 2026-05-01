pub struct Repository {
    store: HashMap<String, AggregateState>,
    next_id: u64,
    aggregate_type: String,
    data_dir: Option<String>,
    identified_by: Option<String>,
    /// Bounded context (bluebook namespace) — set by Runtime when the
    /// aggregate's IR carries one. Used to namespace the heki path
    /// (i142 Tier 2) so same-name aggregates in different contexts
    /// don't collide on storage. None = legacy aggregate with flat
    /// heki path (the pre-i142 default).
    context: Option<String>,
}

