    /// Rebuild on the explicit `Backend::Memory` ONLY those aggregates whose
    /// governing hecksagon declares `:memory` — matched by `agg.context ==
    /// hecksagon.name`, the same per-context scoping as
    /// `apply_sqlite_persistence`. Until this ran, `:memory` was INERT : a
    /// declared-`:memory` aggregate fell through to the implicit heki default
    /// `boot_with_data_dir` built, so `:memory` and `unwired` were
    /// indistinguishable on disk. Now `:memory` actually selects in-process
    /// memory — the keystone for "tests get memory, production fails loud on
    /// unwired". Every other aggregate keeps its heki repository. A no-op when
    /// no `:memory` hecksagon is attached. Memory is host- AND wasm-valid, so
    /// — unlike `apply_sqlite_persistence` — this carries no cfg gate.
    pub(super) fn apply_memory_persistence(&mut self) {
        let memory_contexts: std::collections::HashSet<&str> = self
            .hecksagons
            .iter()
            .filter(|hex| hex.persistence.as_deref() == Some("memory"))
            .map(|hex| hex.name.as_str())
            .collect();
        if memory_contexts.is_empty() {
            return;
        }
        // Collect patches under the immutable borrow of self.domain, then apply
        // them under the mutable borrow of self.repositories — mirrors
        // apply_sqlite_persistence's two-phase borrow discipline.
        let patches: Vec<(String, String, Option<String>, Option<String>)> = self
            .domain
            .aggregates
            .iter()
            .filter(|agg| {
                agg.context
                    .as_deref()
                    .map_or(false, |ctx| memory_contexts.contains(ctx))
            })
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