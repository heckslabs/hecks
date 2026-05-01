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
use super::{interpreter, lifecycle};
use std::collections::HashMap;

#[derive(Debug, Clone)]
pub struct CommandResult {
    pub aggregate_id: String,
    pub aggregate_type: String,
    pub event: Option<Event>,
}

pub fn dispatch(
    rt: &mut Runtime,
    command_name: &str,
    attrs: HashMap<String, Value>,
) -> Result<CommandResult, RuntimeError> {
    let (agg_idx, cmd_idx) = resolve(rt, command_name)?;

    // Many-form dispatch (i113 / i116) — when the command takes a single
    // `list_of(VO)` attribute and the VO carries the aggregate's
    // identity field, treat the dispatch as a bulk register : iterate
    // the list, save one record per spec, emit one event per row.
    // Falls through to single-row dispatch when the shape doesn't
    // match. Detection is purely by IR shape, no naming convention :
    // any command that meets the contract gets the loop for free.
    if let Some(spec_attr) = bulk_spec_attr(rt, agg_idx, cmd_idx) {
        return dispatch_bulk(rt, agg_idx, cmd_idx, command_name, &spec_attr, attrs);
    }

    let is_create = command_name.starts_with("Create")
        || command_name.starts_with("Add")
        || command_name.starts_with("Place")
        || command_name.starts_with("Register")
        || command_name.starts_with("Open");

    let self_ref = find_self_ref(rt, agg_idx, cmd_idx);
    let aggregate_name = rt.domain.aggregates[agg_idx].name.clone();
    let aggregate_context = rt.domain.aggregates[agg_idx].context.clone();
    let repo_hash_key = super::repo_key(aggregate_context.as_deref(), &aggregate_name);

    let repo = rt.repositories.get_mut(&repo_hash_key)
        .ok_or_else(|| RuntimeError::UnknownAggregate(aggregate_name.clone()))?;

    let (mut state, is_new) = if let Some(ref_name) = &self_ref {
        if let Some(id_val) = attrs.get(ref_name) {
            let id = id_val.to_string();
            match repo.find(&id).cloned() {
                Some(s) => (s, false),
                None => return Err(RuntimeError::AggregateNotFound(id)),
            }
        } else if is_create {
            (AggregateState::new(&repo.id_for_command(&attrs)), true)
        } else {
            return Err(RuntimeError::MissingAttribute("self-referencing id".into()));
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
    let cmd = &rt.domain.aggregates[agg_idx].commands[cmd_idx];
    interpreter::check_givens(cmd, &state, &attrs)?;
    lifecycle::check(rt, agg_idx, cmd_idx, &state)?;
    interpreter::apply_mutations(cmd, &mut state, &attrs);
    lifecycle::apply_transition(rt, agg_idx, cmd_idx, &mut state);

    // Create commands copy matching attrs to aggregate
    if is_new {
        let agg_attr_names: Vec<&str> = rt.domain.aggregates[agg_idx]
            .attributes.iter().map(|a| a.name.as_str()).collect();
        let cmd = &rt.domain.aggregates[agg_idx].commands[cmd_idx];
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

    let event = build_event(rt, agg_idx, cmd_idx, &aggregate_id, &attrs);
    if let Some(ref evt) = event {
        rt.event_bus.publish(evt.clone());
    }

    Ok(CommandResult {
        aggregate_id,
        aggregate_type: aggregate_name,
        event,
    })
}

/// Resolve a command address to a (aggregate_index, command_index).
///
/// Three forms are accepted, in order of specificity (i142 — bluebooks
/// as bounded contexts) :
///
///   - `Context.Aggregate.Command` — three dotted parts. Filters
///     aggregates by both context (bluebook namespace) and aggregate
///     name. The most specific form ; resolves cross-context
///     same-name aggregates correctly (e.g. `Boot.Identity.Identify`
///     vs `Being.Identity.RecordSession`).
///
///   - `Aggregate.Command` — two dotted parts. Filters by aggregate
///     name only ; if multiple aggregates share that name across
///     contexts, returns the first match. Backward compat for the
///     pre-i142 form.
///
///   - `Command` — bare command name. Walks every command in every
///     aggregate ; returns the first match. Legacy form ; ambiguous
///     when multiple aggregates declare the same command name. Used
///     by direct-runtime callers (tests, programmatic dispatch) ;
///     production CLI now passes the full prefix.
fn resolve(rt: &Runtime, command_name: &str) -> Result<(usize, usize), RuntimeError> {
    let parts: Vec<&str> = command_name.split('.').collect();
    match parts.as_slice() {
        [context, agg_name, cmd_name] => {
            for (ai, agg) in rt.domain.aggregates.iter().enumerate() {
                if agg.name != *agg_name { continue; }
                if agg.context.as_deref() != Some(*context) { continue; }
                for (ci, cmd) in agg.commands.iter().enumerate() {
                    if cmd.name == *cmd_name { return Ok((ai, ci)); }
                }
            }
            Err(RuntimeError::UnknownCommand(command_name.to_string()))
        }
        [agg_name, cmd_name] => {
            for (ai, agg) in rt.domain.aggregates.iter().enumerate() {
                if agg.name != *agg_name { continue; }
                for (ci, cmd) in agg.commands.iter().enumerate() {
                    if cmd.name == *cmd_name { return Ok((ai, ci)); }
                }
            }
            Err(RuntimeError::UnknownCommand(command_name.to_string()))
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
            let strict = std::env::var("HECKS_STRICT_DISPATCH")
                .map(|v| v == "1" || v == "true")
                .unwrap_or(false);
            if strict {
                let mut hits: Vec<(usize, usize, &str)> = Vec::new();
                for (ai, agg) in rt.domain.aggregates.iter().enumerate() {
                    for (ci, cmd) in agg.commands.iter().enumerate() {
                        if cmd.name == *cmd_name {
                            hits.push((ai, ci, agg.name.as_str()));
                        }
                    }
                }
                match hits.len() {
                    0 => Err(RuntimeError::UnknownCommand(command_name.to_string())),
                    1 => Ok((hits[0].0, hits[0].1)),
                    _ => {
                        let mut candidates: Vec<&str> = hits.iter().map(|h| h.2).collect();
                        candidates.sort();
                        candidates.dedup();
                        Err(RuntimeError::AmbiguousCommand {
                            name: cmd_name.to_string(),
                            candidates: candidates.into_iter().map(String::from).collect(),
                        })
                    }
                }
            } else {
                for (ai, agg) in rt.domain.aggregates.iter().enumerate() {
                    for (ci, cmd) in agg.commands.iter().enumerate() {
                        if cmd.name == *cmd_name { return Ok((ai, ci)); }
                    }
                }
                Err(RuntimeError::UnknownCommand(command_name.to_string()))
            }
        }
        _ => Err(RuntimeError::UnknownCommand(command_name.to_string())),
    }
}

fn find_self_ref(rt: &Runtime, agg_idx: usize, cmd_idx: usize) -> Option<String> {
    let agg = &rt.domain.aggregates[agg_idx];
    let cmd = &agg.commands[cmd_idx];
    let agg_snake = to_snake_case(&agg.name);
    for r in &cmd.references {
        let ref_snake = to_snake_case(&r.target);
        if ref_snake == agg_snake || agg_snake.ends_with(&ref_snake) {
            // Return the reference's actual name (which may be aliased
            // via `role: :incident_id`), not the snake-cased target.
            // The runner / DSL passes the kwarg under r.name; the
            // runtime must look up under the same key.
            return Some(r.name.clone());
        }
    }
    None
}

fn apply_lifecycle_default(rt: &Runtime, agg_idx: usize, state: &mut AggregateState) {
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

fn build_event(
    rt: &Runtime, agg_idx: usize, cmd_idx: usize,
    aggregate_id: &str, attrs: &HashMap<String, Value>,
) -> Option<Event> {
    let agg = &rt.domain.aggregates[agg_idx];
    let cmd = &agg.commands[cmd_idx];
    let event_name = cmd.emits.clone().unwrap_or_else(|| {
        if let Some(rest) = cmd.name.strip_prefix("Create") {
            format!("{}Created", rest)
        } else if let Some(rest) = cmd.name.strip_prefix("Add") {
            format!("{}Added", rest)
        } else if let Some(rest) = cmd.name.strip_prefix("Place") {
            format!("{}Placed", rest)
        } else if let Some(rest) = cmd.name.strip_prefix("Cancel") {
            format!("{}Cancelled", rest)
        } else if let Some(rest) = cmd.name.strip_prefix("Update") {
            format!("{}Updated", rest)
        } else if let Some(rest) = cmd.name.strip_prefix("Remove") {
            format!("{}Removed", rest)
        } else if let Some(rest) = cmd.name.strip_prefix("Delete") {
            format!("{}Deleted", rest)
        } else {
            format!("{}Completed", cmd.name)
        }
    });
    Some(Event {
        name: event_name,
        aggregate_type: agg.name.clone(),
        aggregate_id: aggregate_id.to_string(),
        data: attrs.clone(),
    })
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
