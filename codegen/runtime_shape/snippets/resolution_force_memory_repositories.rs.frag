    /// Replace every repository with an explicit `Backend::Memory` wrapper.
    /// Safe post-boot because the lazy repos are still un-hydrated (no disk
    /// touch yet) — the same swap `apply_per_domain_world_dirs` performs.
    pub(super) fn force_memory_repositories(&mut self) {
        let patches: Vec<(String, String, Option<String>, Option<String>)> = self
            .domain
            .aggregates
            .iter()
            .map(|agg| {
                (
                    repo_key(agg.context.as_deref(), &agg.name),
                    agg.name.clone(),
                    agg.identified_by.clone(),
                    agg.context.clone(),
                )
            })
            .collect();
        for (key, name, identified_by, context) in patches {
            self.repositories
                .insert(key, LazyRepository::new_memory(&name, identified_by, context));
        }
    }
