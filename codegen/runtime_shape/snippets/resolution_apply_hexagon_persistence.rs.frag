    /// Bucket-3 step 4 — the hexagon-binding CONSULT. Where
    /// `apply_memory_persistence` / `apply_sqlite_persistence` read the LEGACY
    /// `.hecksagon` persistence block (`hex.persistence`), this reads the NEW
    /// port-verb binding surface — `Pizzas::Order.persisted_by("Heki")` — that
    /// steps 1-3 parse + resolve. It runs `resolve_bindings` over the loaded IR
    /// and, for every bind that resolves on the `persistence` family, rebuilds
    /// that aggregate's repository on the backend its adapter NAMES — so the
    /// runtime OBEYS the declaration rather than coinciding with the heki
    /// default. Additive : an aggregate with no persistence binding keeps the
    /// repository `boot_with_data_dir` built. Runs AFTER apply_memory /
    /// apply_sqlite, so where an aggregate ever carried BOTH a legacy block and
    /// a binding the binding (the new surface) is last-writer ; no corpus
    /// aggregate carries both today.
    ///
    /// adapter-name → backend : "Heki" rebuilds heki at the runtime `data_dir`
    /// — the SAME constructor `boot_with_data_dir` uses, so it is byte-identical
    /// to the default, now binding-driven ; "Memory" selects the explicit
    /// in-process `Backend::Memory` (the discriminating case that proves the
    /// consult bites). Sqlite via the binding surface is not exercised —
    /// `adapter :sqlite, db:` still routes through `apply_sqlite_persistence`'s
    /// legacy block (fallible, db-path-carrying), so an unrecognised
    /// persistence-family adapter leaves the default repo untouched. Ungated :
    /// like memory, the heki/memory constructors are host- AND wasm-valid.
    pub(super) fn apply_hexagon_persistence(&mut self) {
        use super::hexagon_resolution::{resolve_bindings, ResolveOutcome};
        // (aggregate FQN, adapter) for every bind resolving on the persistence
        // family. resolve_bindings already type-checked the adapter->family->verb
        // attach ; an unresolved bind never reaches here.
        let binds: Vec<(String, String)> = resolve_bindings(&self.hecksagons)
            .into_iter()
            .filter_map(|r| match r.outcome {
                ResolveOutcome::Resolved { family } if family == "persistence" => {
                    Some((r.aggregate, r.adapter))
                }
                _ => None,
            })
            .collect();
        if binds.is_empty() {
            return;
        }
        let data_dir = self.data_dir.clone();
        // Resolve each bound FQN to its repo_key + ctor params under the
        // immutable borrow ; patch under the mutable borrow — the two-phase
        // discipline apply_memory_persistence uses. The bind's aggregate IS the
        // FQN, which equals `repo_key(context, name)`.
        let patches: Vec<(String, String, Option<String>, Option<String>, String)> = self
            .domain
            .aggregates
            .iter()
            .filter_map(|agg| {
                let key = repo_key(agg.context.as_deref(), &agg.name);
                binds.iter().find(|(fqn, _)| *fqn == key).map(|(_, adapter)| {
                    (
                        key.clone(),
                        agg.name.clone(),
                        agg.identified_by.clone(),
                        agg.context.clone(),
                        adapter.clone(),
                    )
                })
            })
            .collect();
        for (key, name, identified_by, context, adapter) in patches {
            let repo = match adapter.as_str() {
                "Memory" => LazyRepository::new_memory(&name, identified_by, context),
                "Heki" => LazyRepository::new(&name, data_dir.clone(), identified_by, context),
                // AppendLog — the bluebook-first Event Log. READS from the same
                // data_dir as Heki (the merged event.heki) ; SAVE appends to a
                // per-process shard. Same ctor signature as Heki.
                "AppendLog" => LazyRepository::new_appendlog(&name, data_dir.clone(), identified_by, context),
                // A persistence-family adapter the consult does not mint (e.g. a
                // future Sqlite binding) leaves the default repo in place.
                _ => continue,
            };
            self.repositories.insert(key, repo);
        }
    }