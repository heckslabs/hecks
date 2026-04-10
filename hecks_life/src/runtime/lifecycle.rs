//! Lifecycle enforcement — checks and applies state transitions
//!
//! Aggregates with a lifecycle block constrain which commands
//! can run based on the current state of a designated field.
//!
//! Usage:
//!   check_lifecycle(rt, agg_idx, cmd_idx, &state)?;
//!   apply_lifecycle_transition(rt, agg_idx, cmd_idx, &mut state);

use super::{AggregateState, Runtime, RuntimeError, Value};

/// Verify the command is allowed given the current lifecycle state.
pub fn check(
    rt: &Runtime, agg_idx: usize, cmd_idx: usize, state: &AggregateState,
) -> Result<(), RuntimeError> {
    let agg = &rt.domain.aggregates[agg_idx];
    let cmd = &agg.commands[cmd_idx];
    let lifecycle = match &agg.lifecycle {
        Some(lc) => lc,
        None => return Ok(()),
    };
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

/// Apply the lifecycle transition if one matches.
pub fn apply_transition(
    rt: &Runtime, agg_idx: usize, cmd_idx: usize, state: &mut AggregateState,
) {
    let agg = &rt.domain.aggregates[agg_idx];
    let cmd = &agg.commands[cmd_idx];
    let lifecycle = match &agg.lifecycle {
        Some(lc) => lc,
        None => return,
    };
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
