//! Usage section — auto-generated workflow from bluebook structure
//!
//! Infers the "how to use this" from create commands, policies,
//! fixtures, and command goals. No manual docs needed.
//!
//! Usage:
//!   let html = usage_section(&domain);

use crate::ir::{Domain, Command, Aggregate};
use super::html_shared::{display_name, esc};

/// Generate the usage/workflow section for a domain page.
/// Reads the bluebook structure and produces a step-by-step guide.
pub fn usage_section(domain: &Domain) -> String {
    let steps = infer_workflow(domain);
    if steps.is_empty() { return String::new(); }

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

    // Workflow steps
    s.push_str(r#"<ol class="space-y-3">"#);
    for (i, step) in steps.iter().enumerate() {
        let num = i + 1;
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

        s.push_str(&format!(
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
        ));
    }
    s.push_str("</ol>");

    // Policies as English sentences
    if !domain.policies.is_empty() {
        s.push_str(r#"<div class="mt-4 pt-3 border-t border-surface-3">"#);
        s.push_str(r#"<p class="text-xs text-gray-500 uppercase tracking-wider mb-2">Automatic behaviors</p>"#);
        s.push_str(r#"<ul class="space-y-1">"#);
        for p in &domain.policies {
            let event = event_to_english(&p.on_event);
            let action = command_to_english(&p.trigger_command);
            s.push_str(&format!(
                r#"<li class="text-sm text-gray-300"><span class="text-gray-500">When</span> {} <span class="text-gray-500">then automatically</span> <span class="text-emerald-400">{}</span></li>"#,
                esc(&event), esc(&action),
            ));
        }
        s.push_str("</ul></div>");
    }

    s.push_str("</div>");
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
/// 1. Create commands first (no reference_to)
/// 2. Then action commands in aggregate order
/// 3. Link events to policies
fn infer_workflow(domain: &Domain) -> Vec<WorkflowStep> {
    let mut steps: Vec<WorkflowStep> = Vec::new();

    // Collect create commands first — they're the entry points
    for agg in &domain.aggregates {
        for cmd in &agg.commands {
            if cmd.references.is_empty() {
                steps.push(step_from(cmd, agg, domain));
            }
        }
    }

    // Then action commands (have reference_to = operate on existing records)
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

    // Find fixture example for this aggregate
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

/// Turn an event name into English: "EntryAdded" → "an entry is added"
fn event_to_english(event: &str) -> String {
    let words = split_pascal(event);
    if words.len() < 2 { return words.join(" ").to_lowercase(); }

    // Last word is usually the past tense verb: Added, Created, Configured
    let verb = &words[words.len() - 1];
    let subject: String = words[..words.len() - 1].join(" ").to_lowercase();

    // Pick article
    let article = if starts_with_vowel(&subject) { "an" } else { "a" };

    // Convert past-tense event verbs to present passive
    let action = match verb.to_lowercase().as_str() {
        "added" => "is added",
        "created" => "is created",
        "configured" => "is configured",
        "connected" => "is connected",
        "disconnected" => "is disconnected",
        "calculated" => "is calculated",
        "checked" => "is checked",
        "generated" => "is generated",
        "defined" => "is defined",
        "flagged" => "is flagged",
        "estimated" => "is estimated",
        "registered" => "is registered",
        "deployed" => "is deployed",
        "retired" => "is retired",
        "tracked" => "is tracked",
        "printed" => "is printed",
        "launched" => "is launched",
        "completed" => "is completed",
        "measured" => "is measured",
        "reported" => "is reported",
        "selected" => "is selected",
        "sized" => "is sized",
        "tripped" => "trips",
        "reset" => "is reset",
        _ => {
            // Fallback: "Xed" → "is xed"
            return format!("{} {} {}", article, subject, verb.to_lowercase());
        }
    };

    format!("{} {} {}", article, subject, action)
}

/// Turn a command name into English: "CalculateTotals" → "calculate totals"
fn command_to_english(cmd: &str) -> String {
    split_pascal(cmd).join(" ").to_lowercase()
}

/// Split PascalCase into words, keeping acronyms together
fn split_pascal(name: &str) -> Vec<String> {
    let chars: Vec<char> = name.chars().collect();
    let mut words: Vec<String> = Vec::new();
    let mut cur = String::new();
    let mut i = 0;
    while i < chars.len() {
        if chars[i].is_uppercase() {
            let start = i;
            while i < chars.len() && chars[i].is_uppercase() { i += 1; }
            let run = i - start;
            if run == 1 {
                if !cur.is_empty() { words.push(cur.clone()); cur.clear(); }
                cur.push(chars[start]);
                while i < chars.len() && chars[i].is_lowercase() { cur.push(chars[i]); i += 1; }
            } else {
                if !cur.is_empty() { words.push(cur.clone()); cur.clear(); }
                if i < chars.len() && chars[i].is_lowercase() {
                    words.push(chars[start..i-1].iter().collect());
                    cur.push(chars[i-1]);
                    while i < chars.len() && chars[i].is_lowercase() { cur.push(chars[i]); i += 1; }
                } else {
                    words.push(chars[start..i].iter().collect());
                }
            }
        } else {
            cur.push(chars[i]);
            i += 1;
        }
    }
    if !cur.is_empty() { words.push(cur); }
    words
}

fn starts_with_vowel(s: &str) -> bool {
    s.chars().next().map_or(false, |c| "aeiou".contains(c.to_lowercase().next().unwrap_or(' ')))
}
