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

    let repo = rt.repositories.get_mut(&repo_hash_key)
        .ok_or_else(|| RuntimeError::UnknownAggregate(aggregate_name.clone()))?;

    let (mut state, is_new) = if let Some(ref_name) = &self_ref {
        if let Some(id_val) = attrs.get(ref_name) {
            let id = id_val.to_string();
            match repo.find(&id).cloned() {
                Some(s) => (s, false),
                None => return Err(RuntimeError::AggregateNotFound(id)),
            }
        } else if let Some(ref id) = cascade_id {
            // Cascade hint resolved a same-type id — reuse it even
            // when the command has a self-ref kwarg the cascade didn't
            // populate (the upstream event carries the id, not the
            // kwarg name).
            match repo.find(id).cloned() {
                Some(s) => (s, false),
                None => return Err(RuntimeError::AggregateNotFound(id.clone())),
            }
        } else if is_create {
            (AggregateState::new(&repo.id_for_command(&attrs)), true)
        } else {
            return Err(RuntimeError::MissingAttribute("self-referencing id".into()));
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
        rt.event_bus.publish(evt.clone());
    }

    Ok(CommandResult {
        aggregate_id,
        aggregate_type: aggregate_name,
        event,
    })
}

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
/// Mirrors lifecycle::check but routes through Resolution so entity
/// commands consult the entity's lifecycle when present (falls back
/// to the parent aggregate's lifecycle otherwise).
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
/// Mirrors lifecycle::apply_transition with entity awareness (i111-J).
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
        rt.event_bus.publish(event.clone());
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
    let repo = rt
        .repositories
        .get_mut(&repo_hash_key)
        .ok_or_else(|| RuntimeError::UnknownAggregate(aggregate_name.to_string()))?;
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
