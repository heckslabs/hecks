//! Usage section — auto-generated workflow from bluebook structure
//!
//! Mirrors the Workflow aggregate from DomainNarration bluebook.
//! Infers "how to use this" from create commands, policies,
//! fixtures, and command goals. Delegates English translation
//! to html_narration, chain tracing to html_policy_chain,
//! and rule collection to html_rules.
//!
//! Usage:
//!   let html = usage_section(&domain);

use crate::ir::{Domain, Command, Aggregate};
use super::html_shared::{display_name, esc};
use super::html_narration::{event_to_english, command_to_english};
use super::html_policy_chain::trace_chain;
use super::html_rules::collect_invariants;

/// Generate the usage/workflow section for a domain page.
/// Reads the bluebook structure and produces a step-by-step guide.
pub fn usage_section(domain: &Domain) -> String {
    let steps = infer_workflow(domain);
    if steps.is_empty() { return String::new(); }

    let mut s = String::new();
    s.push_str(&render_header(domain));
    s.push_str(&render_steps(&steps));
    s.push_str(&render_policies(domain));
    s.push_str(&render_rules(domain));
    s.push_str("</div>");
    s
}

fn render_header(domain: &Domain) -> String {
    let vision = domain.vision.as_deref().unwrap_or("");
    let mut s = String::new();
    s.push_str(r#"<div class="mb-8 bg-surface-1 rounded-xl border border-surface-3 p-6">"#);
    s.push_str(&format!(
        r#"<h2 class="text-lg font-bold text-brand mb-1">How to use {name}</h2>"#,
        name = esc(&display_name(&domain.name)),
    ));
    if !vision.is_empty() {
        s.push_str(&format!(
            r#"<p class="text-sm text-gray-400 mb-4">{}</p>"#,
            esc(vision),
        ));
    }
    s
}

fn render_steps(steps: &[WorkflowStep]) -> String {
    let mut s = String::new();
    s.push_str(r#"<ol class="space-y-3">"#);
    for (i, step) in steps.iter().enumerate() {
        s.push_str(&render_one_step(i + 1, step));
    }
    s.push_str("</ol>");
    s
}

fn render_one_step(num: usize, step: &WorkflowStep) -> String {
    let event_html = step.emits.as_ref().map(|e| format!(
        r#" <span class="text-xs text-emerald-400 ml-2">→ {}</span>"#,
        esc(&display_name(e)),
    )).unwrap_or_default();
    let policy_html = step.triggers.as_ref().map(|t| format!(
        r#"<span class="text-xs text-amber-400 ml-1">→ auto: {}</span>"#,
        esc(&display_name(t)),
    )).unwrap_or_default();
    let example_html = if !step.example.is_empty() {
        let pairs: Vec<String> = step.example.iter()
            .map(|(k, v)| format!(
                r#"<span class="text-gray-500">{}</span>=<span class="text-gray-300">{}</span>"#,
                esc(k), esc(v),
            ))
            .collect();
        format!(r#"<div class="mt-1 text-xs font-mono text-gray-500">e.g. {}</div>"#, pairs.join(" "))
    } else {
        String::new()
    };
    let role_html = step.role.as_ref().map(|r| format!(
        r#" <span class="text-xs text-gray-500 ml-1">as {}</span>"#, esc(r),
    )).unwrap_or_default();

    format!(
        r#"<li class="flex gap-3">
  <span class="flex-shrink-0 w-7 h-7 rounded-full bg-brand/20 text-brand text-sm font-bold flex items-center justify-center">{num}</span>
  <div>
    <p class="text-sm"><span class="font-semibold text-white">{cmd}</span>{role} — {goal}{event}{policy}</p>
    <p class="text-xs text-gray-500 mt-0.5">{agg}</p>
    {example}
  </div>
</li>"#,
        num = num,
        cmd = esc(&display_name(&step.command)),
        role = role_html,
        goal = esc(&step.goal),
        event = event_html,
        policy = policy_html,
        agg = esc(&display_name(&step.aggregate)),
        example = example_html,
    )
}

fn render_policies(domain: &Domain) -> String {
    if domain.policies.is_empty() { return String::new(); }

    // Group policies by trigger event
    let mut groups: Vec<(String, Vec<&crate::ir::Policy>)> = Vec::new();
    for p in &domain.policies {
        if let Some(g) = groups.iter_mut().find(|(ev, _)| *ev == p.on_event) {
            g.1.push(p);
        } else {
            groups.push((p.on_event.clone(), vec![p]));
        }
    }

    let mut s = String::new();
    s.push_str(r#"<div class="mt-4 pt-3 border-t border-surface-3">"#);
    s.push_str(r#"<p class="text-xs text-gray-500 uppercase tracking-wider mb-2">Automatic behaviors</p>"#);
    s.push_str(r#"<ul class="space-y-2">"#);
    for (event_name, policies) in &groups {
        let event = event_to_english(event_name);
        s.push_str(&format!(
            r#"<li class="text-sm text-gray-300"><span class="text-gray-500">When</span> {}:"#,
            esc(&event),
        ));
        for p in policies {
            let action = command_to_english(&p.trigger_command);
            s.push_str(&format!(
                r#"<br><span class="text-emerald-400 ml-4">→ {}</span>"#,
                esc(&action),
            ));
            for (evt, cmd) in &trace_chain(&p.trigger_command, domain) {
                s.push_str(&format!(
                    r#"<br><span class="text-gray-600 ml-8">↳ which emits</span> <span class="text-gray-400">{}</span> <span class="text-gray-600">→</span> <span class="text-emerald-400">{}</span>"#,
                    esc(&event_to_english(evt)), esc(&command_to_english(cmd)),
                ));
            }
        }
        s.push_str("</li>");
    }
    s.push_str("</ul></div>");
    s
}

fn render_rules(domain: &Domain) -> String {
    let invariants = collect_invariants(domain);
    if invariants.is_empty() { return String::new(); }
    let mut s = String::new();
    s.push_str(r#"<div class="mt-4 pt-3 border-t border-surface-3">"#);
    s.push_str(r#"<p class="text-xs text-gray-500 uppercase tracking-wider mb-2">Rules</p>"#);
    s.push_str(r#"<ul class="space-y-1">"#);
    for (cmd_name, rule) in &invariants {
        s.push_str(&format!(
            r#"<li class="text-sm text-white">{} requires {}</li>"#,
            esc(&display_name(cmd_name)), esc(rule),
        ));
    }
    s.push_str("</ul></div>");
    s
}

struct WorkflowStep {
    command: String,
    aggregate: String,
    goal: String,
    role: Option<String>,
    emits: Option<String>,
    triggers: Option<String>,
    example: Vec<(String, String)>,
}

/// Infer workflow steps from domain structure.
/// Create commands first (no reference_to), then action commands.
fn infer_workflow(domain: &Domain) -> Vec<WorkflowStep> {
    let mut steps: Vec<WorkflowStep> = Vec::new();
    for agg in &domain.aggregates {
        for cmd in &agg.commands {
            if cmd.references.is_empty() {
                steps.push(step_from(cmd, agg, domain));
            }
        }
    }
    for agg in &domain.aggregates {
        for cmd in &agg.commands {
            if !cmd.references.is_empty() {
                steps.push(step_from(cmd, agg, domain));
            }
        }
    }
    steps
}

fn step_from(cmd: &Command, agg: &Aggregate, domain: &Domain) -> WorkflowStep {
    let triggers = cmd.emits.as_ref().and_then(|event| {
        domain.policies.iter()
            .find(|p| p.on_event == *event)
            .map(|p| p.trigger_command.clone())
    });
    let example: Vec<(String, String)> = domain.fixtures.iter()
        .find(|f| f.aggregate_name == agg.name)
        .map(|f| f.attributes.iter()
            .take(3)
            .map(|(k, v)| (k.clone(), v.clone()))
            .collect()
        )
        .unwrap_or_default();

    WorkflowStep {
        command: cmd.name.clone(),
        aggregate: agg.name.clone(),
        goal: cmd.description.as_deref()
            .or(cmd.emits.as_deref())
            .unwrap_or("Execute this command")
            .to_string(),
        role: cmd.role.clone(),
        emits: cmd.emits.clone(),
        triggers,
        example,
    }
}
