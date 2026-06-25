    pub fn find(&self, aggregate_name: &str, id: &str) -> Option<&AggregateState> {
        // Exact-key fast path — when the caller passes either the bare
        // name (single-context corpus) or a fully-qualified
        // `Context::Name` key (post-i142), match it directly.
        if let Some(repo) = self.repositories.get(aggregate_name) {
            if let Some(state) = repo.find(id) {
                return Some(state);
            }
        }
        // Context-disambiguation path — when multiple contexts declare
        // an aggregate with the same name (e.g. self/Conversation,
        // capabilities/cloudflare_deploy/MiettePhone::Conversation),
        // repo_lookup_key picks
        // a first hash-iter match nondeterministically. Walk every
        // key ending with `::<name>` and return the FIRST one whose
        // store actually carries the id — the id itself disambiguates
        // which context the dispatch landed in.
        let suffix = format!("::{}", aggregate_name);
        for (key, repo) in &self.repositories {
            if key.ends_with(&suffix) {
                if let Some(state) = repo.find(id) {
                    return Some(state);
                }
            }
        }
        None
    }

