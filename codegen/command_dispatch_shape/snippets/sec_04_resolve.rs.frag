/// Resolve a command address to a Resolution (aggregate or entity-owned).
///
/// ## Canonical form — i560 v2 FQN migration (2026-05-12)
///
///   - `Domain::Aggregate.Command` (commands, PascalCase)
///   - `Domain::Aggregate.query_name` (queries, snake_case)
///
///     Two `::`-separated segments followed by `.<Command-or-query>`.
///
///     - `Domain` matches against an aggregate's `context` (bluebook
///       namespace, set by `Hecks.bluebook "X"`) OR against the
///       bluebook's `category` (the directory under `aggregates/`,
///       e.g. `discipline`, `framework`, `world`). Case-insensitive.
///     - `Aggregate` matches the aggregate's `name`.
///     - The post-`.` token is PascalCase for commands and snake_case
///       for queries.
///
///   This is the form the CLI accepts (`storehouse <root>
///   Domain::Aggregate.Command`). The CLI gate in `main.rs` rejects
///   the legacy short forms with a helpful error naming the canonical
///   shape. The resolver below still accepts the legacy dotted forms
///   so internal cascade machinery (`drain_policies`,
///   `dispatch_cascade`) keeps working — bluebook `trigger_command`
///   strings are typically declared as `Aggregate.Command` in source
///   today, and rewriting every bluebook is out of scope for this
///   sidequest.
///
/// ## Legacy forms (accepted for internal cascade use)
///
///   - `Context.Aggregate.Command` — three dotted parts (i142 form).
///   - `Aggregate.Entity.Command` — three dotted parts that don't
///     match a known context (i111-J).
///   - `Aggregate.Command` — two dotted parts.
///   - `Command` — bare command name.
fn resolve(rt: &Runtime, command_name: &str) -> Result<Resolution, RuntimeError> {
    // i560 v2 — canonical FQN form first. Presence of `::` is the
    // discriminator ; the rest falls through to the legacy dotted
    // forms that internal cascade dispatch relies on.
    if command_name.contains("::") {
        return resolve_fully_qualified(rt, command_name);
    }
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
            Err(RuntimeError::UnknownCommand(
                unknown_command_message_3part(rt, command_name, a, b, c)
            ))
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
                Err(RuntimeError::UnknownCommand(
                    unknown_command_message_2part(rt, command_name, agg_name, cmd_name)
                ))
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
                    0 => Err(RuntimeError::UnknownCommand(
                        unknown_command_message_bare(rt, command_name)
                    )),
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
                Err(RuntimeError::UnknownCommand(
                    unknown_command_message_bare(rt, command_name)
                ))
            }
        }
        _ => Err(RuntimeError::UnknownCommand(format!(
            "{} — malformed dispatch address (canonical form is 'Domain::Aggregate.Command' or 'Domain::Aggregate.query_name'; legacy forms still accepted for cascade: 'Command', 'Aggregate.Command', 'Context.Aggregate.Command', 'Aggregate.Entity.Command')",
            command_name
        ))),
    }
}

/// Parse the canonical fully-qualified form `Domain::Aggregate.Command`
/// (or `.query_name`) into component parts. Returns Err with a
/// helpful message naming the canonical shape when the input doesn't
/// conform.
///
/// Returned tuple: (domain, aggregate, command_or_query)
///
/// i560 v2 (2026-05-12) — the v1 attempt targeted 3 segments
/// (`Domain::Aggregate::Aggregate.Command`) and produced redundant
/// duplication like `Tools::Tools::Tools.Bash`. v2 collapses to 2
/// segments + dot : `Tools::Tools.Bash`, `Discipline::Macrophage.Run`.
pub fn parse_fqn(command_name: &str) -> Result<(String, String, String), String> {
    let (head, tail) = match command_name.rsplit_once('.') {
        Some(pair) => pair,
        None => {
            return Err(format!(
                "calling format is Domain::Aggregate.Command (queries: .query_name lowercase) — got '{}'",
                command_name
            ));
        }
    };
    if tail.is_empty() || head.is_empty() {
        return Err(format!(
            "calling format is Domain::Aggregate.Command (queries: .query_name lowercase) — got '{}'",
            command_name
        ));
    }
    let segments: Vec<&str> = head.split("::").collect();
    if segments.len() != 2 {
        return Err(format!(
            "calling format is Domain::Aggregate.Command (queries: .query_name lowercase) — got '{}' (expected 2 '::'-separated segments before the '.')",
            command_name
        ));
    }
    Ok((
        segments[0].to_string(),
        segments[1].to_string(),
        tail.to_string(),
    ))
}

/// Resolve the fully-qualified canonical form
/// `Domain::Aggregate.Command`. The trailing token is the command
/// name (PascalCase) ; queries are resolved by the query layer using
/// `parse_fqn` directly, so this function only returns a Resolution
/// for command-shaped addresses.
fn resolve_fully_qualified(rt: &Runtime, command_name: &str) -> Result<Resolution, RuntimeError> {
    let (domain, target, cmd) = match parse_fqn(command_name) {
        Ok(parts) => parts,
        Err(msg) => return Err(RuntimeError::UnknownCommand(msg)),
    };

    let domain_lc = domain.to_lowercase();

    // First pass — aggregate-rooted command (target == aggregate name).
    for (ai, agg) in rt.domain.aggregates.iter().enumerate() {
        if agg.name != target { continue; }
        if !domain_matches(rt, ai, &domain, &domain_lc) { continue; }
        for (ci, c) in agg.commands.iter().enumerate() {
            if c.name == cmd {
                return Ok(Resolution::Aggregate(ai, ci));
            }
        }
    }

    // Second pass — entity-owned command. The canonical form uses the
    // entity name in the command (e.g. `Discipline::Macrophage.CheckRegister`
    // for a Register command on the Check entity). But for parity with
    // the legacy `Aggregate.Entity.Command` form, we also accept lookups
    // where `target` is an aggregate name and the command lives on one
    // of its entities — useful for one-shot dispatches without renaming
    // the entity command.
    for (ai, agg) in rt.domain.aggregates.iter().enumerate() {
        if agg.name != target { continue; }
        if !domain_matches(rt, ai, &domain, &domain_lc) { continue; }
        for (ei, ent) in agg.entities.iter().enumerate() {
            for (ci, c) in ent.commands.iter().enumerate() {
                if c.name == cmd {
                    return Ok(Resolution::Entity(ai, ei, ci));
                }
            }
        }
    }

    Err(RuntimeError::UnknownCommand(format!(
        "{} — no command at this address. Checked domain '{}' for aggregate '{}' and command '{}'.",
        command_name, domain, target, cmd
    )))
}

/// Does the FQN's first segment match the aggregate's bluebook
/// context or category? Case-insensitive match — `Discipline` and
/// `discipline` both resolve to `category "discipline"`.
fn domain_matches(rt: &Runtime, agg_idx: usize, domain: &str, domain_lc: &str) -> bool {
    let agg = &rt.domain.aggregates[agg_idx];
    if agg.context.as_deref() == Some(domain) { return true; }
    if let Some(ref ctx) = agg.context {
        if ctx.to_lowercase() == *domain_lc { return true; }
    }
    // i560 v2 — match against the aggregate's stamped category so
    // `Discipline::Macrophage.Run` resolves through the merged corpus.
    if let Some(ref cat) = agg.category {
        if cat == domain || cat.to_lowercase() == *domain_lc { return true; }
    }
    // Single-domain fallback : when the runtime was booted from a
    // single .bluebook the per-Domain category is still set.
    if let Some(ref cat) = rt.domain.category {
        if cat.to_lowercase() == *domain_lc { return true; }
    }
    false
}

