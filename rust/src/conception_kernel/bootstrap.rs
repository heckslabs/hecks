//! conception_kernel::bootstrap — self-reference detection and bootstrap-command
//! selection. Pure IR selectors, plan-independent.
//!
//! `self_ref_for` answers "does this command operate on an EXISTING entity of
//! its own aggregate?" — the kwarg name the runner injects from in_scope, or None
//! when the command creates rather than mutates. `pick_create_command` answers
//! "which command can bootstrap a fresh entity of this aggregate?" — a prefixed,
//! self-ref-free command. Both are prefix/shape selectors over the IR; neither
//! recurses or threads ProducedState, so they live below the planner. The setup
//! orchestration (command_test) and `query_test` both call `pick_create_command`;
//! generator.rs delegates to both until it is deleted at the final gate.
//!
//! Usage:
//!   let create = conception_kernel::bootstrap::pick_create_command(agg);

use crate::ir::{Aggregate, Command};
use crate::parser_helpers::to_snake_case;

/// The kwarg name of `cmd`'s self-reference (a reference whose target matches
/// its own aggregate, by exact snake-case or suffix), or None when the command
/// has no self-ref — i.e. it bootstraps rather than mutates an existing entity.
/// Uses `r.name` (which honors `role: :alias`) so this matches
/// command_dispatch::find_self_ref — both must agree on the kwarg the runner
/// injects from in_scope.
pub fn self_ref_for(agg: &Aggregate, cmd: &Command) -> Option<String> {
    let agg_snake = to_snake_case(&agg.name);
    for r in &cmd.references {
        let ref_snake = to_snake_case(&r.target);
        if ref_snake == agg_snake || agg_snake.ends_with(&ref_snake) {
            return Some(r.name.clone());
        }
    }
    None
}

/// Pick a command that can bootstrap a fresh entity of `agg`. A bootstrap
/// command must not have a self-ref (otherwise it requires an existing entity
/// to operate on); cross-refs are fine — the runner resolves them from in_scope
/// at dispatch. Prefers create-style prefixes in priority order, falling back to
/// the first self-ref-free command.
pub fn pick_create_command(agg: &Aggregate) -> Option<&Command> {
    let is_bootstrap = |c: &&Command| self_ref_for(agg, c).is_none();

    let prefixes = [
        "Create", "Define", "Place", "Register", "Open", "Plan", "Spawn", "Boot",
        "Start", "Initialize", "Seed", "Provision", "Issue",
    ];
    for prefix in &prefixes {
        if let Some(c) = agg
            .commands
            .iter()
            .find(|c| c.name.starts_with(prefix) && is_bootstrap(c))
        {
            return Some(c);
        }
    }
    agg.commands.iter().find(is_bootstrap)
}
