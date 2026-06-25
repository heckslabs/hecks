    /// For each reference on the triggered command, inject an id under its
    /// kwarg name if not already present:
    ///   - target matches upstream event's aggregate type → use event's id
    ///   - target is the command's own aggregate (self-ref) and a record
    ///     exists in that repo → use the existing record's id
    ///   - target is any other aggregate with an existing record (singleton
    ///     pattern) → use that record's id
    /// The bluebook stays reference-only; the runtime resolves to ids.
    fn inject_refs(
        &self,
        cmd_name: &str,
        upstream_type: &str,
        upstream_id: &str,
        data: &mut HashMap<String, Value>,
    ) {
        for agg in &self.domain.aggregates {
            for cmd in &agg.commands {
                if cmd.name != cmd_name { continue; }
                for r in &cmd.references {
                    if data.contains_key(&r.name) { continue; }
                    if r.target == upstream_type {
                        data.insert(r.name.clone(), Value::Str(upstream_id.to_string()));
                        continue;
                    }
                    // Singleton fallback: pick any existing record of the
                    // ref's target type. References don't carry context ;
                    // resolve target's context by scanning the loaded
                    // domain (i142 Tier 2). True cross-context refs land
                    // in Tier 3.
                    //
                    // i161 — when the same aggregate name lives in
                    // multiple contexts (e.g. Mind.Musing + Musings.Musing
                    // post-i117 R4), the naive `find()` returns the first
                    // by depth-then-path iteration order, so the wrong
                    // context wins and singleton fallback hits the wrong
                    // repo. The dispatching command is on `agg` ; prefer
                    // a target in the SAME context, fall back to first
                    // match for genuine cross-context refs. Self-refs
                    // (r.target == agg.name) resolve trivially via
                    // agg.context — no domain scan needed.
                    let target_ctx = if r.target == agg.name {
                        agg.context.as_deref()
                    } else {
                        self.domain.aggregates.iter()
                            .find(|a| a.name == r.target && a.context == agg.context)
                            .or_else(|| self.domain.aggregates.iter().find(|a| a.name == r.target))
                            .and_then(|a| a.context.as_deref())
                    };
                    let key = repo_key(target_ctx, &r.target);
                    if let Some(repo) = self.repositories.get(&key) {
                        if let Some(existing) = repo.all().first() {
                            data.insert(r.name.clone(), Value::Str(existing.id.clone()));
                        }
                    }
                }
                // Inject the identity field when the triggered command's
                // aggregate uses identified_by. Two cases this catches:
                //   1. Key absent — policy cascade didn't supply an id.
                //   2. Key present but value doesn't match any record —
                //      upstream aggregate leaked its own identified_by field
                //      (e.g. Pulse's `name="pulse"` in a BodyPulse event) into
                //      the cascade data, pointing at a non-existent record.
                // The injection picks the lexicographically lowest existing
                // record id (deterministic). For natural-key singletons
                // (Heartbeat → "heartbeat", Tick → "tick"), this finds the
                // canonical row even when junk counter-minted records sit
                // alongside it. Without this, every cascade tick creates yet
                // another counter-minted record because id_for_command
                // honored the leaked upstream value.
                if let Some(ref key) = agg.identified_by {
                    let agg_key = repo_key(agg.context.as_deref(), &agg.name);
                    if let Some(repo) = self.repositories.get(&agg_key) {
                        let needs_inject = match data.get(key.as_str()) {
                            None => true,
                            Some(v) => v.as_str()
                                .map(|s| repo.find(s).is_none())
                                .unwrap_or(true),
                        };
                        if needs_inject {
                            // Prefer a record whose id is non-numeric (the
                            // natural-key form, e.g. "heartbeat") over a
                            // counter-minted u64 id ("1", "42", "302" — the
                            // junk left by pre-i80 dispatches). Within each
                            // group fall back to lex-min for determinism.
                            let pick = repo.all().iter()
                                .map(|s| s.id.clone())
                                .min_by(|a, b| {
                                    let an = a.chars().all(|c| c.is_ascii_digit());
                                    let bn = b.chars().all(|c| c.is_ascii_digit());
                                    an.cmp(&bn).then_with(|| a.cmp(b))
                                });
                            if let Some(id) = pick {
                                data.insert(key.clone(), Value::Str(id));
                            } else {
                                // Empty repo + leaked upstream key (i151) —
                                // remove the leaked id so id_for_command
                                // counter-mints a fresh id rather than
                                // creating a record named after the upstream
                                // aggregate (e.g. heartbeat with id="tick"
                                // because Tick.MindstreamTick's name="tick"
                                // leaked through Ticked → Pulse.Emit →
                                // BodyPulse → AccumulateFatigue). Without
                                // this, every singleton aggregate downstream
                                // of a named-key emitter inherits the wrong
                                // identifier on first dispatch and silently
                                // accumulates orphans in subsequent ticks.
                                data.remove(key.as_str());
                            }
                        }
                    }
                }
                return; // first matching command wins
            }
        }
    }

