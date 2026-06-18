    /// i728 is-wired check — repo_keys of aggregates with NO persistence
    /// wiring, i.e. would be UNWIRED. An aggregate is WIRED when EITHER its
    /// governing hecksagon declares a legacy persistence adapter
    /// (`hex.persistence.is_some()` — the `adapter :heki` block, wiring by
    /// CONTEXT) OR it carries a resolved persistence-family binding
    /// (`Pizzas::Order.persisted_by("Heki")` — the hexagon port-verb surface,
    /// wiring by AGGREGATE FQN). Reading BOTH surfaces keeps this check in
    /// step with `apply_hexagon_persistence` (the backend resolver) : every
    /// aggregate the resolver rebinds is reported wired, never a false boot
    /// error. In Phase C a STRICT `.world` turns a non-empty result into a
    /// boot error ; here it is plumbing only — no caller enforces it, and
    /// `boot_in_memory` (the behaviors harness) bypasses it.
    pub fn unwired_aggregates(&self) -> Vec<String> {
        use super::hexagon_resolution::{resolve_bindings, ResolveOutcome};
        // Legacy `adapter :heki` block — wires by CONTEXT (whole hecksagon).
        let wired_contexts: std::collections::HashSet<&str> = self
            .hecksagons
            .iter()
            .filter(|hex| hex.persistence.is_some())
            .map(|hex| hex.name.as_str())
            .collect();
        // Port-verb binding `persisted_by(...)` — wires by AGGREGATE FQN. The
        // bind's aggregate IS the FQN, which equals `repo_key(context, name)`.
        // Mirror apply_hexagon_persistence's filter so the wired check and the
        // backend resolver read the same surface and never diverge.
        let wired_keys: std::collections::HashSet<String> = resolve_bindings(&self.hecksagons)
            .into_iter()
            .filter_map(|r| match r.outcome {
                ResolveOutcome::Resolved { family } if family == "persistence" => Some(r.aggregate),
                _ => None,
            })
            .collect();
        let mut out: Vec<String> = self
            .domain
            .aggregates
            .iter()
            .filter(|agg| {
                let ctx_unwired = agg
                    .context
                    .as_deref()
                    .map_or(true, |ctx| !wired_contexts.contains(ctx));
                let key = repo_key(agg.context.as_deref(), &agg.name);
                ctx_unwired && !wired_keys.contains(&key)
            })
            .map(|agg| repo_key(agg.context.as_deref(), &agg.name))
            .collect();
        out.sort();
        out
    }
