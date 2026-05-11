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
    /// Last mtime we observed on disk for this repo's heki file. Used
    /// by `refresh_from_heki` to skip the read when nothing has changed
    /// since our last load/save. None until the first successful
    /// load_persisted ; updated on every save and every refresh-driven
    /// reload. Mirrors the `last_seen_mtime` attribute declared on the
    /// Repository aggregate in runtime/storage/storage.bluebook.
    last_seen_mtime: Option<SystemTime>,
}

