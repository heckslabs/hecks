//! Command dispatch — the core execution loop
//!
//! Resolves a command name to its aggregate + definition,
//! enforces givens, checks lifecycle, applies mutations,
//! transitions state, persists, and emits.
//!
//! Usage:
//!   let result = dispatch(&mut runtime, "CreatePizza", attrs)?;
//!
//! [antibody-exempt: rust/src/runtime/command_dispatch.rs — kernel-floor
//!  dispatch path. i156 added strict bare-name resolution gated by the
//!  HECKS_STRICT_DISPATCH env var ; the rest of the file is pre-i156.]

use super::{AggregateState, Event, Runtime, RuntimeError, Value};
use super::interpreter;
use crate::ir::{Command, Lifecycle};
use std::collections::HashMap;

#[derive(Debug, Clone)]
pub struct CommandResult {
    pub aggregate_id: String,
    pub aggregate_type: String,
    pub event: Option<Event>,
}

/// Resolution of a dispatch address — i111-J.
///
/// `Aggregate(agg_idx, cmd_idx)` — command lives directly on the
/// aggregate's commands list.
///
/// `Entity(agg_idx, ent_idx, cmd_idx)` — command lives inside an
/// entity declared inside the aggregate's `entity "Foo" do … end`
/// block. Dispatch still operates on the parent aggregate's record
/// (entities are reached only through the root in DDD), but uses the
/// entity's command — its mutations, givens, lifecycle.
#[derive(Debug, Clone, Copy)]
enum Resolution {
    Aggregate(usize, usize),
    Entity(usize, usize, usize),
}

impl Resolution {
    fn agg_idx(&self) -> usize {
        match self {
            Resolution::Aggregate(a, _) => *a,
            Resolution::Entity(a, _, _) => *a,
        }
    }
}

/// Borrow the resolved command from the runtime's IR.
fn cmd_for<'a>(rt: &'a Runtime, res: Resolution) -> &'a Command {
    match res {
        Resolution::Aggregate(a, c) => &rt.domain.aggregates[a].commands[c],
        Resolution::Entity(a, e, c) => &rt.domain.aggregates[a].entities[e].commands[c],
    }
}

/// Borrow the lifecycle that gates the resolved command : the entity's
/// own lifecycle when present, otherwise the parent aggregate's.
fn lifecycle_for<'a>(rt: &'a Runtime, res: Resolution) -> Option<&'a Lifecycle> {
    match res {
        Resolution::Aggregate(a, _) => rt.domain.aggregates[a].lifecycle.as_ref(),
        Resolution::Entity(a, e, _) => rt.domain.aggregates[a].entities[e]
            .lifecycle
            .as_ref()
            .or(rt.domain.aggregates[a].lifecycle.as_ref()),
    }
}

pub fn dispatch(
    rt: &mut Runtime,
    command_name: &str,
    attrs: HashMap<String, Value>,
) -> Result<CommandResult, RuntimeError> {
    dispatch_inner(rt, command_name, attrs, None)
}

/// Cascade-aware dispatch (i111-K) — used by `Runtime::drain_policies`
/// when the triggered command's aggregate has the SAME type as the
/// upstream event. Passing the upstream id as a hint lets the second
/// dispatch reuse the existing record instead of counter-minting a
/// fresh id.
///
/// This closes the i111-C surprise : multi-step pipelines like
/// CorpusPruning (Measure → Split with `given { measured == true }`)
/// previously needed `identified_by` declared just to keep the cascade
/// landing on the same row. With this hint, the cascade preserves the
/// id automatically — `identified_by` becomes a query / addressability
/// concern, not a cascade-correctness requirement.
///
/// The hint is honored only when :
///   - The triggered command's aggregate type matches `upstream_type`
///   - A record already exists at `upstream_id` in that repo
/// Otherwise the dispatch falls through to standard id resolution
/// (identified_by lookup → counter-mint), keeping cross-type cascades
/// and missing-record cases unchanged.
pub fn dispatch_cascade(
    rt: &mut Runtime,
    command_name: &str,
    attrs: HashMap<String, Value>,
    upstream_type: &str,
    upstream_id: &str,
) -> Result<CommandResult, RuntimeError> {
    dispatch_inner(rt, command_name, attrs, Some((upstream_type.to_string(), upstream_id.to_string())))
}

fn dispatch_inner(
    rt: &mut Runtime,
    command_name: &str,
    attrs: HashMap<String, Value>,
    cascade_hint: Option<(String, String)>,
) -> Result<CommandResult, RuntimeError> {
    let res = resolve(rt, command_name)?;
    let agg_idx = res.agg_idx();

    // Many-form dispatch (i113 / i116) — only applies to aggregate-level
    // commands. Entity commands route through the parent's record and
    // don't currently support the list_of(VO) bulk pattern.
    if let Resolution::Aggregate(_, cmd_idx) = res {
        if let Some(spec_attr) = bulk_spec_attr(rt, agg_idx, cmd_idx) {
            return dispatch_bulk(rt, agg_idx, cmd_idx, command_name, &spec_attr, attrs);
        }
    }

    let is_create = command_name.starts_with("Create")
        || command_name.starts_with("Add")
        || command_name.starts_with("Place")
        || command_name.starts_with("Register")
        || command_name.starts_with("Open");

    let self_ref = find_self_ref_res(rt, res);
    let aggregate_name = rt.domain.aggregates[agg_idx].name.clone();
    let aggregate_context = rt.domain.aggregates[agg_idx].context.clone();
    let repo_hash_key = super::repo_key(aggregate_context.as_deref(), &aggregate_name);

    // i111-K — same-type cascade id preservation. When the cascade
    // hopped Aggregate → Aggregate (same type) and a record exists at
    // the upstream id, reuse it. This runs BEFORE id_for_command so it
    // overrides counter-mint behavior for aggregates without
    // identified_by — closing the i111-C identified_by-required gap.
    let cascade_id = cascade_hint.as_ref().and_then(|(up_type, up_id)| {
        if up_type == &aggregate_name {
            rt.repositories.get(&repo_hash_key)
                .and_then(|repo| repo.find(up_id))
                .map(|_| up_id.clone())
        } else {
            None
        }
    });

    // Build the diagnostic up front — borrowing `rt` inside
    // `ok_or_else` collides with the `get_mut` mutable borrow.
    let unknown_agg_msg = if rt.repositories.contains_key(&repo_hash_key) {
        String::new()
    } else {
        unknown_aggregate_message(rt, &aggregate_name)
    };
    // i-cascade-fk : a cross-aggregate cascade (cascade_hint upstream type
    // differs from this aggregate) driving a self-ref command carries the
    // upstream event's leaked `id`, which names the UPSTREAM record, not one
    // of this type. Resolve the owning record from the upstream record's FK
    // (its attribute whose declared type IS this aggregate) so e.g.
    // TaskCompleted -> Story.DropPendingTaskCount finds the Story via Task.story.
    let cascade_fk_id: Option<String> = cascade_hint.as_ref().and_then(|(up_type, up_id)| {
        if up_type == &aggregate_name { return None; }
        // same-context upstream first : in combined-domain mode several
        // domains may share an aggregate name (e.g. Task), so prefer the one
        // in the target's context before falling back to any match.
        let up_agg = rt.domain.aggregates.iter()
            .find(|a| &a.name == up_type && a.context == aggregate_context)
            .or_else(|| rt.domain.aggregates.iter().find(|a| &a.name == up_type))?;
        let fname = up_agg.attributes.iter()
            .find(|at| at.attr_type == aggregate_name)
            .map(|at| at.name.clone())?;
        rt.repositories.get(&super::repo_key(up_agg.context.as_deref(), up_type))
            .and_then(|up| up.find(up_id))
            .and_then(|rec| rec.fields.get(&fname))
            .and_then(|v| v.as_str().map(str::to_string))
    });
    let repo = rt.repositories.get_mut(&repo_hash_key)
        .ok_or(RuntimeError::UnknownAggregate(unknown_agg_msg))?;

    let (mut state, is_new) = if let Some(ref_name) = &self_ref {
        // Universal self-ref dispatch — i519 sidequest. Callers may pass
        // either the snake-cased aggregate name (the historical kwarg
        // determined by `find_self_ref_res`) or the universal `id` key.
        // The snake-cased lookup takes precedence so existing dispatches
        // are byte-identical ; the `id` fallback removes the convention-
        // discovery cliff for new callers (`reference_to(ExemptRegistry)`
        // is no longer "guess `exempt_registry=`").
        //
        // Safety : the `attribute :id` / `reference_to` collision was
        // checked across every bluebook in the corpus at i519-time ; no
        // command declares its own `id` attribute alongside a self-ref.
        // The corpus contract is enforceable by a validator if it ever
        // drifts.
        let self_ref_id = attrs.get(ref_name).map(|v| v.to_string())
            .or_else(|| cascade_fk_id.clone())
            .or_else(|| attrs.get("id").map(|v| v.to_string()));
        if let Some(id) = self_ref_id {
            match repo.find(&id).cloned() {
                Some(s) => (s, false),
                None => return Err(RuntimeError::AggregateNotFound(
                    format!("no aggregate of type '{}' found with id '{}' — the dispatch expected an existing record but none matched (passed via attr '{}')",
                        aggregate_name, id, ref_name)
                )),
            }
        } else if let Some(ref id) = cascade_id {
            // Cascade hint resolved a same-type id — reuse it even
            // when the command has a self-ref kwarg the cascade didn't
            // populate (the upstream event carries the id, not the
            // kwarg name).
            match repo.find(id).cloned() {
                Some(s) => (s, false),
                None => return Err(RuntimeError::AggregateNotFound(
                    format!("no aggregate of type '{}' found with id '{}' — the dispatch expected an existing record but none matched (cascade hint)",
                        aggregate_name, id)
                )),
            }
        } else if is_create {
            (AggregateState::new(&repo.id_for_command(&attrs)), true)
        } else {
            return Err(RuntimeError::MissingAttribute(
                self_ref_missing_message(rt, res, command_name, ref_name)
            ));
        }
    } else if let Some(ref id) = cascade_id {
        // Same-type cascade with an existing record — reuse it,
        // skipping id_for_command's counter-mint.
        match repo.find(id).cloned() {
            Some(s) => (s, false),
            None => (AggregateState::new(id), true),
        }
    } else {
        let id = repo.id_for_command(&attrs);
        match repo.find(&id).cloned() {
            Some(s) => (s, false),
            None => (AggregateState::new(&id), true),
        }
    };

    if is_new {
        apply_defaults(rt, agg_idx, &mut state);
        apply_lifecycle_default(rt, agg_idx, &mut state);
    }

    // Pipeline: givens → lifecycle check → mutations → lifecycle transition
    let cmd = cmd_for(rt, res);
    interpreter::check_givens(cmd, &state, &attrs)?;
    check_lifecycle(rt, res, &state)?;
    interpreter::apply_mutations(cmd, &mut state, &attrs);
    apply_lifecycle_transition(rt, res, &mut state);

    // f4 — aggregate-level invariants are checked on the RESULTING state
    // (post-mutation, post-transition) before save. A violated invariant
    // rejects the command exactly like a failed `given` : 0 events, no save.
    // An invariant is a `given` enforced on every command.
    if let Some(violated) = crate::invariants::check_invariants(
        &rt.domain.aggregates[agg_idx].invariants,
        &state,
        &attrs,
    ) {
        return Err(RuntimeError::InvariantViolation {
            name: violated.name.clone(),
            expression: violated.expression.clone(),
        });
    }

    // Create commands copy matching attrs to aggregate. For entity
    // commands the parent aggregate's attribute set is the target
    // schema (entities live within the parent's record).
    if is_new {
        let agg_attr_names: Vec<&str> = rt.domain.aggregates[agg_idx]
            .attributes.iter().map(|a| a.name.as_str()).collect();
        let cmd = cmd_for(rt, res);
        for cmd_attr in &cmd.attributes {
            if agg_attr_names.contains(&cmd_attr.name.as_str()) {
                if let Some(val) = attrs.get(&cmd_attr.name) {
                    state.set(&cmd_attr.name, val.clone());
                }
            }
        }
    }

    let aggregate_id = state.id.clone();
    let was_deleted = state.deleted;
    let ctx = crate::heki::WriteContext::Dispatch {
        aggregate: &aggregate_name, command: command_name,
    };
    let repo = rt.repositories.get_mut(&repo_hash_key).unwrap();
    if was_deleted {
        repo.delete(&aggregate_id, ctx);
    } else {
        repo.save(state, ctx);
    }

    let event = build_event_res(rt, res, &aggregate_id, &attrs);
    if let Some(ref evt) = event {
        // Sprint 14 (migration-coexistence) — fork on the aggregate's
        // declared `delivery` mode. `Sync` (default for every aggregate
        // without `delivery :actor`) publishes inline as today. `Actor`
        // routes through `enqueue_and_drain`, the per-aggregate mailbox
        // stub. The stub publishes synchronously too (see the helper's
        // doc comment) so behavior is byte-equivalent ; the difference
        // is observable on `Runtime::mailbox_drained` which behaviors
        // tests assert on to prove the fork fired.
        match rt.delivery_for(&evt.aggregate_type) {
            crate::ir::DeliveryMode::Sync => rt.event_bus.publish(evt.clone()),
            crate::ir::DeliveryMode::Actor => rt.enqueue_and_drain(evt.clone()),
        }
    }

    Ok(CommandResult {
        aggregate_id,
        aggregate_type: aggregate_name,
        event,
    })
}

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

/// Resolution-aware self-ref finder (i111-J). For an entity command,
/// the self-ref still points at the parent aggregate's record because
/// the entity is reached through the root. The reference's actual
/// name (which may be aliased via `role: :incident_id`) is what the
/// runner / DSL passes the kwarg under ; the runtime must look up
/// under the same key.
fn find_self_ref_res(rt: &Runtime, res: Resolution) -> Option<String> {
    let agg_idx = res.agg_idx();
    let agg = &rt.domain.aggregates[agg_idx];
    let cmd = cmd_for(rt, res);
    let agg_snake = to_snake_case(&agg.name);
    for r in &cmd.references {
        let ref_snake = to_snake_case(&r.target);
        if ref_snake == agg_snake || agg_snake.ends_with(&ref_snake) {
            return Some(r.name.clone());
        }
    }
    None
}

/// Verify the command is allowed given the current lifecycle state.
/// Routes through Resolution so entity commands consult the entity's
/// lifecycle when present (falls back to the parent aggregate's
/// lifecycle otherwise).
fn check_lifecycle(
    rt: &Runtime, res: Resolution, state: &AggregateState,
) -> Result<(), RuntimeError> {
    let lifecycle = match lifecycle_for(rt, res) {
        Some(lc) => lc,
        None => return Ok(()),
    };
    let cmd = cmd_for(rt, res);
    let matching: Vec<_> = lifecycle.transitions.iter()
        .filter(|t| t.command == cmd.name).collect();
    if matching.is_empty() { return Ok(()); }

    let current = format!("{}", state.get(&lifecycle.field));
    let allowed = matching.iter().any(|t| match &t.from_state {
        Some(from) => current == *from,
        None => true,
    });
    if allowed { Ok(()) } else {
        Err(RuntimeError::LifecycleViolation {
            command: cmd.name.clone(),
            field: lifecycle.field.clone(),
            current,
            allowed: matching.iter().filter_map(|t| t.from_state.clone()).collect(),
        })
    }
}

/// Apply the lifecycle transition if one matches the resolved command.
/// Resolution-aware (i111-J) — entity commands consult the entity's
/// lifecycle when present, otherwise the parent aggregate's.
fn apply_lifecycle_transition(rt: &Runtime, res: Resolution, state: &mut AggregateState) {
    let lifecycle = match lifecycle_for(rt, res) {
        Some(lc) => lc,
        None => return,
    };
    let cmd = cmd_for(rt, res);
    let current = format!("{}", state.get(&lifecycle.field));
    for t in &lifecycle.transitions {
        if t.command != cmd.name { continue; }
        let from_ok = match &t.from_state {
            Some(from) => current == *from,
            None => true,
        };
        if from_ok {
            state.set(&lifecycle.field, Value::Str(t.to_state.clone()));
            return;
        }
    }
}

pub(crate) fn apply_lifecycle_default(rt: &Runtime, agg_idx: usize, state: &mut AggregateState) {
    let agg = &rt.domain.aggregates[agg_idx];
    if let Some(ref lc) = agg.lifecycle {
        if matches!(state.get(&lc.field), Value::Null) {
            state.set(&lc.field, Value::Str(lc.default.clone()));
        }
    }
}

fn apply_defaults(rt: &Runtime, agg_idx: usize, state: &mut AggregateState) {
    let agg = &rt.domain.aggregates[agg_idx];
    let vo_names: Vec<&str> = agg.value_objects.iter().map(|vo| vo.name.as_str()).collect();
    for attr in &agg.attributes {
        if let Some(ref default) = attr.default {
            state.set(&attr.name, parse_default(default, &attr.attr_type));
        } else if attr.list || vo_names.contains(&attr.attr_type.as_str()) {
            state.set(&attr.name, Value::List(vec![]));
        }
    }
}

/// Resolution-aware event builder (i111-J). Entity commands emit
/// events tagged with the parent aggregate's name — that's the
/// addressable record from outside the bounded context — but use
/// the entity command's `emits:` declaration when present.
fn build_event_res(
    rt: &Runtime, res: Resolution,
    aggregate_id: &str, attrs: &HashMap<String, Value>,
) -> Option<Event> {
    let agg_idx = res.agg_idx();
    let agg = &rt.domain.aggregates[agg_idx];
    let cmd = cmd_for(rt, res);
    let event_name = cmd.emits.clone().unwrap_or_else(|| default_event_name(&cmd.name));
    Some(Event {
        name: event_name,
        aggregate_type: agg.name.clone(),
        aggregate_id: aggregate_id.to_string(),
        data: attrs.clone(),
    })
}

fn default_event_name(cmd_name: &str) -> String {
    if let Some(rest) = cmd_name.strip_prefix("Create") {
        format!("{}Created", rest)
    } else if let Some(rest) = cmd_name.strip_prefix("Add") {
        format!("{}Added", rest)
    } else if let Some(rest) = cmd_name.strip_prefix("Place") {
        format!("{}Placed", rest)
    } else if let Some(rest) = cmd_name.strip_prefix("Cancel") {
        format!("{}Cancelled", rest)
    } else if let Some(rest) = cmd_name.strip_prefix("Update") {
        format!("{}Updated", rest)
    } else if let Some(rest) = cmd_name.strip_prefix("Remove") {
        format!("{}Removed", rest)
    } else if let Some(rest) = cmd_name.strip_prefix("Delete") {
        format!("{}Deleted", rest)
    } else {
        format!("{}Completed", cmd_name)
    }
}

fn parse_default(default: &str, attr_type: &str) -> Value {
    match attr_type {
        "Integer" => Value::Int(default.parse().unwrap_or(0)),
        "Boolean" => Value::Bool(default == "true"),
        _ => Value::Str(default.trim_matches('"').to_string()),
    }
}

fn to_snake_case(s: &str) -> String {
    crate::parser_helpers::to_snake_case(s)
}

// ============================================================
// Error-message helpers — turn bare error variants into
// caller-actionable diagnostics. Wraps useful corpus context
// (available commands, aggregate names, expected self-ref attr
// names) into the String payload so the existing variant shape
// stays untouched but the caller sees what to fix.
// ============================================================

/// List every aggregate visible in the loaded domains, in
/// `Context.Aggregate` form when a context is set so the caller
/// can disambiguate same-name aggregates across bluebooks.
fn available_aggregate_names(rt: &Runtime) -> Vec<String> {
    let mut names: Vec<String> = rt.domain.aggregates.iter()
        .map(|a| match &a.context {
            Some(ctx) => format!("{}.{}", ctx, a.name),
            None => a.name.clone(),
        })
        .collect();
    names.sort();
    names.dedup();
    names
}

/// List every command declared on a specific aggregate (by name),
/// across every bluebook the aggregate appears in. Returned in
/// `Aggregate.Command` form. Includes entity-owned commands as
/// `Aggregate.Entity.Command` so the caller can see the i111-J
/// addressable surface too.
fn commands_on_aggregate(rt: &Runtime, agg_name: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for agg in rt.domain.aggregates.iter().filter(|a| a.name == agg_name) {
        for cmd in &agg.commands {
            out.push(format!("{}.{}", agg.name, cmd.name));
        }
        for ent in &agg.entities {
            for cmd in &ent.commands {
                out.push(format!("{}.{}.{}", agg.name, ent.name, cmd.name));
            }
        }
    }
    out.sort();
    out.dedup();
    out
}

/// List every command in every aggregate/entity in the corpus, in
/// fully-qualified form. Used as the fallback hint for bare-name
/// dispatch misses where we have no aggregate context to narrow
/// the listing by.
fn all_commands_qualified(rt: &Runtime) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for agg in &rt.domain.aggregates {
        let agg_prefix = match &agg.context {
            Some(ctx) => format!("{}.{}", ctx, agg.name),
            None => agg.name.clone(),
        };
        for cmd in &agg.commands {
            out.push(format!("{}.{}", agg_prefix, cmd.name));
        }
        for ent in &agg.entities {
            for cmd in &ent.commands {
                out.push(format!("{}.{}.{}", agg_prefix, ent.name, cmd.name));
            }
        }
    }
    out.sort();
    out.dedup();
    out
}

/// Truncate a candidates list for the error string. Long
/// listings (1000+ commands across the corpus) would drown the
/// error ; the cap keeps the message useful without hiding
/// information silently — the truncated count is included.
fn join_truncated(items: &[String], cap: usize) -> String {
    if items.len() <= cap {
        items.join(", ")
    } else {
        format!("{}, … ({} more)", items[..cap].join(", "), items.len() - cap)
    }
}

fn unknown_aggregate_message(rt: &Runtime, agg_name: &str) -> String {
    let avail = available_aggregate_names(rt);
    if avail.is_empty() {
        format!("{} — no aggregates loaded in this runtime", agg_name)
    } else {
        format!(
            "{} — no aggregate by that name in the loaded domains. Available: {}",
            agg_name,
            join_truncated(&avail, 40),
        )
    }
}

fn unknown_command_message_3part(
    rt: &Runtime, full: &str, a: &str, b: &str, c: &str,
) -> String {
    // 3-part form means either Context.Aggregate.Command or
    // Aggregate.Entity.Command. The caller almost certainly
    // intended one of those — list commands on each candidate
    // aggregate so they can self-correct.
    let mut hints: Vec<String> = Vec::new();
    // Context.Aggregate.Command : aggregates named `b` in context `a`.
    for agg in rt.domain.aggregates.iter()
        .filter(|agg| agg.name == b && agg.context.as_deref() == Some(a))
    {
        for cmd in &agg.commands {
            hints.push(format!("{}.{}.{}", a, b, cmd.name));
        }
    }
    // Aggregate.Entity.Command : aggregates named `a` with entity `b`.
    for agg in rt.domain.aggregates.iter().filter(|agg| agg.name == a) {
        for ent in agg.entities.iter().filter(|e| e.name == b) {
            for cmd in &ent.commands {
                hints.push(format!("{}.{}.{}", a, b, cmd.name));
            }
        }
    }
    hints.sort();
    hints.dedup();
    if hints.is_empty() {
        // No aggregate context matched at all — fall back to a
        // corpus-wide listing so they see what IS available.
        let all = all_commands_qualified(rt);
        format!(
            "{} — no command at that address. Looked for Context.Aggregate.Command ('{}.{}') and Aggregate.Entity.Command ('{}.{}'); neither matched. Available commands: {}",
            full, a, b, a, b,
            join_truncated(&all, 30),
        )
    } else {
        format!(
            "{} — '{}' not declared at that address. Did you mean: {}",
            full, c, join_truncated(&hints, 20),
        )
    }
}

fn unknown_command_message_2part(
    rt: &Runtime, full: &str, agg_name: &str, cmd_name: &str,
) -> String {
    let on_agg = commands_on_aggregate(rt, agg_name);
    if on_agg.is_empty() {
        // The aggregate part itself doesn't exist.
        let aggs = available_aggregate_names(rt);
        format!(
            "{} — no aggregate '{}' in the loaded domains. Available aggregates: {}",
            full, agg_name, join_truncated(&aggs, 40),
        )
    } else {
        format!(
            "{} — command '{}' not declared on '{}'. Available on this aggregate: {}",
            full, cmd_name, agg_name, join_truncated(&on_agg, 30),
        )
    }
}

fn unknown_command_message_bare(rt: &Runtime, cmd_name: &str) -> String {
    let all = all_commands_qualified(rt);
    if all.is_empty() {
        format!("{} — no commands declared in the loaded domains", cmd_name)
    } else {
        format!(
            "{} — no command by that name in the loaded domains. Available: {}",
            cmd_name, join_truncated(&all, 30),
        )
    }
}

/// Compose the "you need to pass a self-ref kwarg" error message.
/// Names the command and the expected attribute names — both the
/// reference's own `name` (which is what gets passed) and the
/// universal `id` fallback so the caller can pick either form.
fn self_ref_missing_message(
    rt: &Runtime, res: Resolution, command_name: &str, ref_name: &str,
) -> String {
    let cmd = cmd_for(rt, res);
    // Collect the reference target so the message names what's
    // being addressed (e.g. "reference_to Pizza" → mention Pizza).
    let target_hint = cmd.references.iter()
        .find(|r| &r.name == ref_name)
        .map(|r| format!(" (reference_to {})", r.target))
        .unwrap_or_default();
    format!(
        "command '{}' requires self-ref attribute '{}=<id>' or 'id=<id>'{}",
        command_name, ref_name, target_hint,
    )
}

// ============================================================
// Many-form bulk dispatch — i113 / i116
// ============================================================
//
// A command qualifies as bulk when it takes exactly one attribute,
// that attribute is a `list_of(VO)` whose VO is declared on the same
// aggregate, the aggregate has `identified_by :field`, and the VO
// carries that identity field. The dispatcher then iterates the list,
// builds per-row attrs from the VO's fields, and runs each row through
// the standard save path so upsert + audit semantics carry through.

/// Return the bulk-spec attribute name when the command meets the bulk
/// shape contract ; otherwise None. Pure shape inspection — no naming
/// convention, no command-prefix rules.
fn bulk_spec_attr(rt: &Runtime, agg_idx: usize, cmd_idx: usize) -> Option<String> {
    let agg = &rt.domain.aggregates[agg_idx];
    let cmd = &agg.commands[cmd_idx];
    let id_field = agg.identified_by.as_deref()?;

    if cmd.attributes.len() != 1 {
        return None;
    }
    let attr = &cmd.attributes[0];
    if !attr.list {
        return None;
    }
    let vo = agg.value_objects.iter().find(|v| v.name == attr.attr_type)?;
    let vo_has_id = vo.attributes.iter().any(|a| a.name == id_field);
    if !vo_has_id {
        return None;
    }
    Some(attr.name.clone())
}

/// Iterate the spec list, dispatch one save per row through the
/// standard pipeline, emit one event per row. The event is published
/// so policies and projections see each row exactly as if it had been
/// dispatched single-form. The returned CommandResult points at the
/// LAST row's aggregate id — callers that need every id should listen
/// on the event bus instead.
fn dispatch_bulk(
    rt: &mut Runtime,
    agg_idx: usize,
    cmd_idx: usize,
    command_name: &str,
    spec_attr: &str,
    attrs: HashMap<String, Value>,
) -> Result<CommandResult, RuntimeError> {
    let specs = match attrs.get(spec_attr) {
        Some(Value::List(items)) => items.clone(),
        Some(Value::Str(s)) => parse_specs_from_str(s)?,
        Some(other) => {
            return Err(RuntimeError::MissingAttribute(format!(
                "{}: expected list_of(VO), got {:?}",
                spec_attr, other
            )));
        }
        None => {
            return Err(RuntimeError::MissingAttribute(spec_attr.to_string()));
        }
    };

    let aggregate_name = rt.domain.aggregates[agg_idx].name.clone();
    let event_name = rt.domain.aggregates[agg_idx].commands[cmd_idx]
        .emits
        .clone()
        .unwrap_or_else(|| format!("{}Completed", command_name));

    let vo_field_names: Vec<String> = {
        let cmd_attr = &rt.domain.aggregates[agg_idx].commands[cmd_idx].attributes[0];
        let vo = rt.domain.aggregates[agg_idx]
            .value_objects
            .iter()
            .find(|v| v.name == cmd_attr.attr_type)
            .expect("bulk_spec_attr already verified VO exists");
        vo.attributes.iter().map(|a| a.name.clone()).collect()
    };

    let mut last_id = String::new();
    let mut last_event: Option<Event> = None;
    for spec in &specs {
        let row_attrs = spec_to_attrs(spec, &vo_field_names);
        let row_id = save_one_row(rt, agg_idx, &aggregate_name, command_name, &row_attrs)?;
        let event = Event {
            name: event_name.clone(),
            aggregate_type: aggregate_name.clone(),
            aggregate_id: row_id.clone(),
            data: row_attrs,
        };
        // Sprint 14 (migration-coexistence) — same fork as the single-
        // event site in phase_11_emit ; many-form (`list_of(VO)`) inputs
        // publish one event per row and each row obeys the aggregate's
        // delivery mode.
        match rt.delivery_for(&event.aggregate_type) {
            crate::ir::DeliveryMode::Sync => rt.event_bus.publish(event.clone()),
            crate::ir::DeliveryMode::Actor => rt.enqueue_and_drain(event.clone()),
        }
        last_id = row_id;
        last_event = Some(event);
    }

    Ok(CommandResult {
        aggregate_id: last_id,
        aggregate_type: aggregate_name,
        event: last_event,
    })
}

/// Coerce a Value (Map or Str-encoded JSON object) into a per-row
/// attrs hash. Map fields are picked up directly ; a Str body is
/// parsed as JSON when the VO field set is known.
fn spec_to_attrs(spec: &Value, vo_fields: &[String]) -> HashMap<String, Value> {
    match spec {
        Value::Map(m) => m.clone(),
        Value::Str(s) => {
            // Best-effort JSON object parse for CLI-passed specs.
            if let Ok(serde_json::Value::Object(map)) = serde_json::from_str::<serde_json::Value>(s) {
                let mut out = HashMap::new();
                for f in vo_fields {
                    if let Some(v) = map.get(f) {
                        out.insert(f.clone(), json_to_value(v));
                    }
                }
                out
            } else {
                HashMap::new()
            }
        }
        _ => HashMap::new(),
    }
}

fn json_to_value(v: &serde_json::Value) -> Value {
    match v {
        serde_json::Value::String(s) => Value::Str(s.clone()),
        serde_json::Value::Bool(b) => Value::Bool(*b),
        serde_json::Value::Number(n) => {
            if let Some(i) = n.as_i64() {
                Value::Int(i)
            } else {
                Value::Str(n.to_string())
            }
        }
        serde_json::Value::Null => Value::Null,
        _ => Value::Str(v.to_string()),
    }
}

/// Parse a string-encoded specs list — the CLI path. Accepts a JSON
/// array of objects ; each object becomes a Value::Map. Anything else
/// surfaces as an error so the caller sees the shape mismatch instead
/// of silently saving zero rows.
fn parse_specs_from_str(s: &str) -> Result<Vec<Value>, RuntimeError> {
    let parsed: serde_json::Value = serde_json::from_str(s)
        .map_err(|e| RuntimeError::MissingAttribute(format!("specs: invalid JSON ({})", e)))?;
    let arr = parsed.as_array().ok_or_else(|| {
        RuntimeError::MissingAttribute("specs: expected JSON array".into())
    })?;
    let mut out = Vec::with_capacity(arr.len());
    for raw in arr {
        if let serde_json::Value::Object(obj) = raw {
            let mut m = HashMap::new();
            for (k, v) in obj {
                m.insert(k.clone(), json_to_value(v));
            }
            out.push(Value::Map(m));
        } else {
            out.push(json_to_value(raw));
        }
    }
    Ok(out)
}

/// Save one row through the standard pipeline — apply defaults, copy
/// matching command attrs onto the aggregate, persist, return the
/// row's id. Mirrors the create path of `dispatch` but skipped the
/// givens / lifecycle plumbing : bulk register has no per-row gates,
/// the command itself is the gate.
fn save_one_row(
    rt: &mut Runtime,
    agg_idx: usize,
    aggregate_name: &str,
    command_name: &str,
    row_attrs: &HashMap<String, Value>,
) -> Result<String, RuntimeError> {
    let repo_hash_key = super::repo_key(
        rt.domain.aggregates[agg_idx].context.as_deref(),
        aggregate_name,
    );
    // Build the diagnostic up front — borrowing `rt` inside
    // `ok_or_else` collides with the `get_mut` mutable borrow.
    let unknown_agg_msg = if rt.repositories.contains_key(&repo_hash_key) {
        String::new()
    } else {
        unknown_aggregate_message(rt, aggregate_name)
    };
    let repo = rt
        .repositories
        .get_mut(&repo_hash_key)
        .ok_or(RuntimeError::UnknownAggregate(unknown_agg_msg))?;
    let id = repo.id_for_command(row_attrs);
    let (mut state, is_new) = match repo.find(&id).cloned() {
        Some(s) => (s, false),
        None => (AggregateState::new(&id), true),
    };
    if is_new {
        apply_defaults(rt, agg_idx, &mut state);
        apply_lifecycle_default(rt, agg_idx, &mut state);
    }

    // Copy every VO field onto the aggregate (path, reason, …) — same
    // semantics as the single-row create path's matching-attrs copy.
    let agg_attr_names: Vec<String> = rt.domain.aggregates[agg_idx]
        .attributes
        .iter()
        .map(|a| a.name.clone())
        .collect();
    for name in &agg_attr_names {
        if let Some(val) = row_attrs.get(name) {
            state.set(name, val.clone());
        }
    }

    let ctx = crate::heki::WriteContext::Dispatch {
        aggregate: aggregate_name,
        command: command_name,
    };
    let repo = rt.repositories.get_mut(&repo_hash_key).unwrap();
    let row_id = state.id.clone();
    repo.save(state, ctx);
    Ok(row_id)
}
