/// Resolve a command address to a Resolution (aggregate or entity-owned).
///
/// Forms accepted, in order of specificity (i142 — bluebooks as bounded
/// contexts ; i111-J — entity-qualified addresses) :
///
///   - `Context.Aggregate.Command` — three dotted parts. Filters
///     aggregates by both context (bluebook namespace) and aggregate
///     name. The most specific form ; resolves cross-context
///     same-name aggregates correctly (e.g. `Boot.Identity.Identify`
///     vs `Being.Identity.RecordSession`).
///
///   - `Aggregate.Entity.Command` — three dotted parts that DON'T
///     match a known context. Resolves to a command declared inside
///     the aggregate's `entity "Foo" do … end` block (i111-J — close
///     the DDD gap). Tried after the context form so a real context
///     match takes precedence.
///
///   - `Aggregate.Command` — two dotted parts. Filters by aggregate
///     name only ; if not found there, walks the aggregate's entities
///     looking for a unique entity-owned command match. Multiple
///     entities owning the same command name on the same aggregate is
///     ambiguous and errors loudly.
///
///   - `Command` — bare command name. Walks every command in every
///     aggregate (and i111-J : every entity within them). First-match-
///     wins ; per-aggregate uniqueness (i155) still holds within a
///     single bluebook. Cross-bluebook strictness is filed as i156.
fn resolve(rt: &Runtime, command_name: &str) -> Result<Resolution, RuntimeError> {
    let parts: Vec<&str> = command_name.split('.').collect();
    match parts.as_slice() {
        [a, b, c] => {
            // Try Context.Aggregate.Command first (i142). If no
            // aggregate is in that context, fall through to the
            // Aggregate.Entity.Command form (i111-J).
            for (ai, agg) in rt.domain.aggregates.iter().enumerate() {
                if agg.name != *b { continue; }
                if agg.context.as_deref() != Some(*a) { continue; }
                for (ci, cmd) in agg.commands.iter().enumerate() {
                    if cmd.name == *c { return Ok(Resolution::Aggregate(ai, ci)); }
                }
            }
            for (ai, agg) in rt.domain.aggregates.iter().enumerate() {
                if agg.name != *a { continue; }
                for (ei, ent) in agg.entities.iter().enumerate() {
                    if ent.name != *b { continue; }
                    for (ci, cmd) in ent.commands.iter().enumerate() {
                        if cmd.name == *c { return Ok(Resolution::Entity(ai, ei, ci)); }
                    }
                }
            }
            Err(RuntimeError::UnknownCommand(command_name.to_string()))
        }
        [agg_name, cmd_name] => {
            // First pass — direct aggregate command match.
            for (ai, agg) in rt.domain.aggregates.iter().enumerate() {
                if agg.name != *agg_name { continue; }
                for (ci, cmd) in agg.commands.iter().enumerate() {
                    if cmd.name == *cmd_name { return Ok(Resolution::Aggregate(ai, ci)); }
                }
            }
            // Second pass (i111-J) — entity-owned command, accepted
            // only when unambiguous (single owning entity within the
            // aggregate). Multiple owners on the same aggregate is a
            // corpus error ; surface it loudly.
            let mut hits: Vec<(usize, usize, usize, String)> = Vec::new();
            for (ai, agg) in rt.domain.aggregates.iter().enumerate() {
                if agg.name != *agg_name { continue; }
                for (ei, ent) in agg.entities.iter().enumerate() {
                    for (ci, cmd) in ent.commands.iter().enumerate() {
                        if cmd.name == *cmd_name {
                            hits.push((ai, ei, ci, ent.name.clone()));
                        }
                    }
                }
            }
            if hits.len() == 1 {
                Ok(Resolution::Entity(hits[0].0, hits[0].1, hits[0].2))
            } else if hits.is_empty() {
                Err(RuntimeError::UnknownCommand(command_name.to_string()))
            } else {
                // Multiple entities of the same aggregate own a command
                // by this name. Without entity disambiguation in the
                // address, the runtime can't pick. Same shape as i156
                // bare-name ambiguity ; reuse UnknownCommand with the
                // candidate list embedded in the message.
                let mut candidates: Vec<String> = hits.iter()
                    .map(|h| format!("{}.{}", agg_name, h.3))
                    .collect();
                candidates.sort();
                candidates.dedup();
                Err(RuntimeError::UnknownCommand(format!(
                    "{} — ambiguous, candidates: {}",
                    command_name,
                    candidates.join(", ")
                )))
            }
        }
        [cmd_name] => {
            // Bare-name dispatch — i156 strict mode (opt-in via the
            // HECKS_STRICT_DISPATCH env var). When strict mode is on AND
            // the bare name appears on more than one aggregate across
            // the loaded corpus, fail loudly with the candidate list
            // instead of silently first-match-wins.
            //
            // Strict mode stays opt-in until the corpus migration is
            // complete (the validator_corpus::bare_name_collisions rule
            // surfaces what's left ; ~107 .behaviors setups already
            // migrated to qualified form by i156 part 2). The i156 PR
            // body documents the gating decision.
            //
            // Default (non-strict) behavior preserves first-match-wins
            // for backward compat — same as before. Per-aggregate
            // uniqueness (i155) still holds within a single bluebook.
            //
            // i111-J — the walk also visits entity-owned commands so
            // collapsed-entity behaviors can still dispatch by short
            // name. Aggregate commands take precedence ; entities are
            // the fallback. Strict-mode collision counts include
            // entity owners alongside aggregate owners.
            let strict = std::env::var("HECKS_STRICT_DISPATCH")
                .map(|v| v == "1" || v == "true")
                .unwrap_or(false);
            if strict {
                let mut hits: Vec<(Resolution, String)> = Vec::new();
                for (ai, agg) in rt.domain.aggregates.iter().enumerate() {
                    for (ci, cmd) in agg.commands.iter().enumerate() {
                        if cmd.name == *cmd_name {
                            hits.push((Resolution::Aggregate(ai, ci), agg.name.clone()));
                        }
                    }
                    for (ei, ent) in agg.entities.iter().enumerate() {
                        for (ci, cmd) in ent.commands.iter().enumerate() {
                            if cmd.name == *cmd_name {
                                hits.push((
                                    Resolution::Entity(ai, ei, ci),
                                    format!("{}.{}", agg.name, ent.name),
                                ));
                            }
                        }
                    }
                }
                match hits.len() {
                    0 => Err(RuntimeError::UnknownCommand(command_name.to_string())),
                    1 => Ok(hits[0].0),
                    _ => {
                        let mut candidates: Vec<String> = hits.iter().map(|h| h.1.clone()).collect();
                        candidates.sort();
                        candidates.dedup();
                        Err(RuntimeError::AmbiguousCommand {
                            name: cmd_name.to_string(),
                            candidates,
                        })
                    }
                }
            } else {
                for (ai, agg) in rt.domain.aggregates.iter().enumerate() {
                    for (ci, cmd) in agg.commands.iter().enumerate() {
                        if cmd.name == *cmd_name { return Ok(Resolution::Aggregate(ai, ci)); }
                    }
                }
                for (ai, agg) in rt.domain.aggregates.iter().enumerate() {
                    for (ei, ent) in agg.entities.iter().enumerate() {
                        for (ci, cmd) in ent.commands.iter().enumerate() {
                            if cmd.name == *cmd_name {
                                return Ok(Resolution::Entity(ai, ei, ci));
                            }
                        }
                    }
                }
                Err(RuntimeError::UnknownCommand(command_name.to_string()))
            }
        }
        _ => Err(RuntimeError::UnknownCommand(command_name.to_string())),
    }
}

