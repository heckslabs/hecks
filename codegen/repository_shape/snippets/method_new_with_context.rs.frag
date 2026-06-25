    /// New repository with bounded-context awareness (i142 Tier 2).
    /// When context is set, the heki path is `<dir>/<context_snake>/<aggregate_snake>.heki`
    /// instead of the flat `<dir>/<aggregate_snake>.heki`. Migrates
    /// flat-path data into the context-prefixed path on first load
    /// (when target dir is empty and source file exists).
    pub fn new_with_context(
        aggregate_type: &str,
        data_dir: Option<String>,
        identified_by: Option<String>,
        context: Option<String>,
    ) -> Self {
        let mut repo = Repository {
            store: HashMap::new(),
            next_id: 1,
            aggregate_type: aggregate_type.to_string(),
            data_dir,
            identified_by,
            context,
            last_seen_mtime: None,
        };
        repo.load_persisted();
        repo
    }
