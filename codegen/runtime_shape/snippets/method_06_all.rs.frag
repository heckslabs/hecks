    pub fn all(&self, aggregate_name: &str) -> Vec<&AggregateState> {
        match repo_lookup_key(&self.repositories, aggregate_name) {
            Some(key) => self.repositories.get(&key).map(|repo| repo.all()).unwrap_or_default(),
            None => Vec::new(),
        }
    }

    /// Context-qualified record retrieval — bypasses repo_lookup_key's
    /// HashMap-iter-order non-determinism by going straight to the
    /// (context, name) repo key. Used by `resolve_query_qualified` so
    /// 3-part `Context.Aggregate.query` lookups read from the right
    /// store when same-name aggregates exist across multiple bluebooks
    /// (e.g. Mind::Musing + Musing::Musing + Musings::Musing — only
    /// one carries the seeded data ; name-only lookup picks one
    /// non-deterministically and silently returns the wrong empty
    /// repo half the time, which is what the dream_content_smoke
    /// flake exposed).
    pub fn all_qualified(&self, context: Option<&str>, aggregate_name: &str)
        -> Vec<&AggregateState>
    {
        match context {
            Some(ctx) if !ctx.is_empty() => {
                let key = repo_key(Some(ctx), aggregate_name);
                self.repositories.get(&key)
                    .map(|repo| repo.all())
                    .unwrap_or_default()
            }
            _ => self.all(aggregate_name),
        }
    }

