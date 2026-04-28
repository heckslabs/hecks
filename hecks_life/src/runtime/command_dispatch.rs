//! Command dispatch — the core execution loop
//!
//! Resolves a command name to its aggregate + definition,
//! enforces givens, checks lifecycle, applies mutations,
//! transitions state, persists, and emits.
//!
//! Usage:
//!   let result = dispatch(&mut runtime, "CreatePizza", attrs)?;

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

    let is_create = command_name.starts_with("Create")
        || command_name.starts_with("Add")
        || command_name.starts_with("Place")
        || command_name.starts_with("Register")
        || command_name.starts_with("Open");

    let self_ref = find_self_ref(rt, agg_idx, cmd_idx);
    let aggregate_name = rt.domain.aggregates[agg_idx].name.clone();

    let repo = rt.repositories.get_mut(&aggregate_name)
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
    let repo = rt.repositories.get_mut(&aggregate_name).unwrap();
    if was_deleted {
        repo.delete(&aggregate_id, ctx);
    } else {
        repo.save(state, ctx);
    }

    let event = build_event(rt, agg_idx, cmd_idx, &aggregate_id, &attrs);
    if let Some(ref evt) = event {
        rt.event_bus.publish(evt.clone());
    }

    // Breadcrumb : write the last dispatched command to a tiny
    // plaintext file under data_dir so the statusline (and any other
    // introspection surface) can read "what just dispatched". Format
    // is two lines :
    //   Aggregate.Command
    //   <unix_seconds>
    // Plaintext, not heki — this is runtime introspection metadata,
    // not domain state ; no audit-log entry, no dispatch context.
    // Writing it failing is silently ignored ; the breadcrumb is
    // best-effort and the statusline degrades gracefully if absent.
    if let Some(ref dir) = rt.data_dir {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs()).unwrap_or(0);
        let path = format!("{}/.last_dispatch", dir.trim_end_matches('/'));
        let _ = std::fs::write(&path,
            format!("{}.{}\n{}\n", aggregate_name, command_name, now));
    }

    Ok(CommandResult {
        aggregate_id,
        aggregate_type: aggregate_name,
        event,
    })
}

fn resolve(rt: &Runtime, command_name: &str) -> Result<(usize, usize), RuntimeError> {
    for (ai, agg) in rt.domain.aggregates.iter().enumerate() {
        for (ci, cmd) in agg.commands.iter().enumerate() {
            if cmd.name == command_name {
                return Ok((ai, ci));
            }
        }
    }
    Err(RuntimeError::UnknownCommand(command_name.to_string()))
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
