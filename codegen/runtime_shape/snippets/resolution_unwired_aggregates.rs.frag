    /// i728 DORMANT is-wired check — repo_keys of aggregates whose governing
    /// hecksagon declares NO persistence adapter (`persistence.is_none()`),
    /// i.e. would be UNWIRED. In Phase C a STRICT `.world` turns a non-empty
    /// result into a boot error ; here it is plumbing only — no caller
    /// enforces it, and `boot_in_memory` (the behaviors harness) bypasses it.
    /// A context is wired when some attached hecksagon names it AND declares
    /// a persistence adapter (mirrors `apply_sqlite_persistence`'s match).
    pub fn unwired_aggregates(&self) -> Vec<String> {
        let wired_contexts: std::collections::HashSet<&str> = self
            .hecksagons
            .iter()
            .filter(|hex| hex.persistence.is_some())
            .map(|hex| hex.name.as_str())
            .collect();
        let mut out: Vec<String> = self
            .domain
            .aggregates
            .iter()
            .filter(|agg| {
                agg.context
                    .as_deref()
                    .map_or(true, |ctx| !wired_contexts.contains(ctx))
            })
            .map(|agg| repo_key(agg.context.as_deref(), &agg.name))
            .collect();
        out.sort();
        out
    }
