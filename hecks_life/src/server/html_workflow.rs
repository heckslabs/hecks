//! Workflow pipeline — visual step rendering for lifecycle aggregates
//!
//! Renders lifecycle states as a horizontal pipeline with arrows,
//! commands grouped under their target state, and invariant gating.
//!
//! Usage:
//!   let html = workflow_pipeline(lifecycle, &aggregate.commands);

use crate::ir::{Lifecycle, Command};
use super::html_shared::{display_name, esc};

/// Turn code expressions into human language
fn humanize_given(expr: &str) -> String {
    // 'status == "draft"' → 'Requires: Draft status'
    if expr.contains("==") {
        let parts: Vec<&str> = expr.split("==").collect();
        if parts.len() == 2 {
            let field = parts[0].trim().trim_matches(|c: char| !c.is_alphanumeric());
            let value = parts[1].trim().trim_matches(|c| c == '"' || c == ' ' || c == '\'');
            return format!("Requires {} to be {}", display_name(field).to_lowercase(), display_name(value).to_lowercase());
        }
    }
    if expr.contains(">") {
        return format!("Requires: {}", expr.replace(">", "greater than").replace("_", " "));
    }
    format!("Requires: {}", expr.replace("_", " "))
}
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
    let (bg, border, text, glow) = if is_default {
        ("bg-brand/20", "border-brand", "text-brand", " shadow-md shadow-brand/20")
    } else if cmds.is_some() {
        ("bg-surface-2", "border-surface-4", "text-gray-200", "")
    } else {
        ("bg-surface-3/50", "border-surface-4/50", "text-gray-500", "")
    };
    let mut s = format!(
        r#"<div class="flex-shrink-0 px-4 py-3 {} border {} rounded-lg text-sm font-medium{}">"#,
        bg, border, glow,
    );
    s.push_str(&format!(r#"<span class="{}">{}</span>"#, text, esc(state)));
    if is_default {
        s.push_str(r#"<div class="text-xs text-gray-500 mt-1">Start</div>"#);
    }
    if let Some(commands) = cmds {
        for cmd in commands {
            let dimmed = if !cmd.givens.is_empty() { " opacity-60" } else { "" };
            let raw = esc(&cmd.name);
            s.push_str(&format!(
                r#"<div class="mt-1.5"><button onclick="var d=document.querySelector('[data-domain-command=&quot;{raw}&quot;]');if(d){{d.open=true;d.scrollIntoView({{behavior:'smooth',block:'center'}})}}" class="text-xs px-2 py-0.5 rounded-full bg-surface-4 text-gray-300 hover:bg-brand/30 hover:text-brand cursor-pointer transition{dimmed}">{display}</button></div>"#,
                raw = raw, dimmed = dimmed, display = esc(&display_name(&cmd.name)),
            ));
            for g in &cmd.givens {
                // Humanize: 'status == "draft"' → 'Requires: Draft status'
                let human = humanize_given(&g.expression);
                s.push_str(&format!(
                    r#"<div class="text-xs text-amber-400/70 mt-0.5">⚠ {}</div>"#,
                    esc(&human),
                ));
            }
        }
    }
    s.push_str("</div>");
    s
}
