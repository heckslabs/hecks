//! Workflow pipeline — visual step rendering for lifecycle aggregates
//!
//! Renders lifecycle states as a horizontal pipeline with arrows,
//! commands grouped under their target state, and invariant gating.
//!
//! Usage:
//!   let html = workflow_pipeline(lifecycle, &aggregate.commands);

use crate::ir::{Lifecycle, Command};
use super::html_shared::{display_name, esc};
use std::collections::HashMap;

/// Render a lifecycle as a horizontal workflow pipeline
pub fn workflow_pipeline(lc: &Lifecycle, commands: &[Command]) -> String {
    let states = ordered_states(lc);
    let cmd_map = commands_by_target_state(lc, commands);
    let mut s = String::from(
        r#"<div class="flex items-center gap-0 mb-6 overflow-x-auto py-2">"#,
    );
    for (i, state) in states.iter().enumerate() {
        if i > 0 {
            s.push_str(r#"<div class="text-gray-600 px-1 flex-shrink-0">→</div>"#);
        }
        s.push_str(&step_node(state, i == 0, cmd_map.get(state.as_str())));
    }
    s.push_str("</div>");
    s
}

/// Collect lifecycle states in order: default first, then transitions
fn ordered_states(lc: &Lifecycle) -> Vec<String> {
    let mut states: Vec<String> = vec![lc.default.clone()];
    for t in &lc.transitions {
        if !states.contains(&t.to_state) {
            states.push(t.to_state.clone());
        }
    }
    states
}

/// Map each target state to the commands that transition into it
fn commands_by_target_state<'a>(
    lc: &Lifecycle, commands: &'a [Command],
) -> HashMap<String, Vec<&'a Command>> {
    let mut map: HashMap<String, Vec<&Command>> = HashMap::new();
    for t in &lc.transitions {
        if let Some(cmd) = commands.iter().find(|c| c.name == t.command) {
            map.entry(t.to_state.clone()).or_default().push(cmd);
        }
    }
    map
}

/// Render one pipeline step node
fn step_node(state: &str, is_default: bool, cmds: Option<&Vec<&Command>>) -> String {
    let (bg, border, text) = if is_default {
        ("bg-brand/20", "border-brand", "text-brand")
    } else {
        ("bg-surface-3", "border-surface-4", "text-gray-300")
    };
    let round = if is_default { " rounded-l-lg" } else { "" };
    let mut s = format!(
        r#"<div class="flex-shrink-0 px-4 py-3 {} border {} text-sm font-medium{}">"#,
        bg, border, round,
    );
    s.push_str(&format!(r#"<span class="{}">{}</span>"#, text, esc(state)));
    if is_default {
        s.push_str(r#"<div class="text-xs text-gray-500 mt-1">Default</div>"#);
    }
    if let Some(commands) = cmds {
        for cmd in commands {
            let dimmed = if !cmd.givens.is_empty() { " opacity-60" } else { "" };
            s.push_str(&format!(
                r#"<div class="text-xs text-gray-400 mt-1{}">{}</div>"#,
                dimmed, esc(&display_name(&cmd.name)),
            ));
            for g in &cmd.givens {
                s.push_str(&format!(
                    r#"<div class="text-xs text-amber-400 mt-0.5">⚠ {}</div>"#,
                    esc(&g.expression),
                ));
            }
        }
    }
    s.push_str("</div>");
    s
}
