        /// Resolve every WIRED persistence binding against the adapter registry,
        /// replacing the heki/memory repository `boot` built with the registered
        /// backend. A hecksagon wires an adapter via `adapter :<token>` (matched
        /// by `agg.context == hecksagon.name`) ; the per-deployment options
        /// (`db:` etc.) ride the hexagon and reach the adapter as the
        /// `PersistenceSpec`. The runtime NAMES NO ENGINE — the concrete adapter
        /// (sqlite, R2, postgres) lives in its own crate and registers itself at
        /// the composition root before boot. A no-op when no aggregate's context
        /// wires a REGISTERED adapter token.
        ///
        /// i735 — EAGER + per-context scoped : construction is fallible, so a
        /// failed build refuses THAT aggregate loudly (drops its repo, records the
        /// reason) rather than panicking the bus or silently falling back to heki.
        #[cfg(not(target_arch = "wasm32"))]
        pub(super) fn apply_wired_adapters(&mut self) {
            // context -> (token, options) for every hecksagon wired to a REGISTERED
            // adapter. Unregistered tokens (heki/memory, or an adapter whose crate
            // the running binary did not link) are skipped : those repos stay as
            // boot built them.
            let wired: HashMap<String, (String, HashMap<String, String>)> = self
                .hecksagons
                .iter()
                .filter_map(|hex| {
                    let token = hex.persistence.as_deref()?;
                    persistence_adapter_factory(token)?;
                    let opts: HashMap<String, String> = hex
                        .persistence_options
                        .iter()
                        .map(|(k, v)| (k.clone(), v.trim_matches('"').to_string()))
                        .collect();
                    Some((hex.name.clone(), (token.to_string(), opts)))
                })
                .collect();
            if wired.is_empty() {
                return;
            }
            // Collect specs under the immutable borrow of self.domain, then build
            // + install under the mutable borrow of self.repositories.
            let specs: Vec<(String, String, PersistenceSpec)> = self
                .domain
                .aggregates
                .iter()
                .filter_map(|agg| {
                    let (token, opts) = agg.context.as_deref().and_then(|ctx| wired.get(ctx))?;
                    let key = repo_key(agg.context.as_deref(), &agg.name);
                    Some((
                        key,
                        token.clone(),
                        PersistenceSpec { aggregate: agg.clone(), options: opts.clone() },
                    ))
                })
                .collect();
            for (key, token, spec) in specs {
                let Some(factory) = persistence_adapter_factory(&token) else { continue };
                // EAGER construction (i735 defect 2) : open + schema + row-load
                // happen now, at boot, because they are FALLIBLE.
                match factory(&spec) {
                    Ok(adapter) => {
                        self.repositories.insert(key, LazyRepository::new_adapter(adapter));
                    }
                    Err(e) => {
                        // Never panic the bus ; never silently fall back to heki.
                        // Refuse THIS aggregate LOUDLY : drop its repo, record why.
                        let reason = format!("{key} : `{token}` persistence refused — {e}");
                        eprintln!("[persistence] {reason}");
                        self.repositories.remove(&key);
                        self.refused_persistence.insert(key, reason);
                    }
                }
            }
        }
