    /// Resolve the heki path for THIS repository — context-prefixed
    /// when context is set (i142 Tier 2), flat otherwise (legacy).
    /// Routes through the canonical `heki::path_for` helper (i145).
    fn heki_path_self(&self, dir: &str) -> String {
        heki::path_for(dir, &self.aggregate_type, self.context.as_deref())
    }
