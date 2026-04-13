//! Training data extraction — turns a bootable domain into a JSONL training pair
//!
//! Each domain becomes one line: the vision is the prompt,
//! the structure is the completion. Only valid domains produce pairs.
//!
//! Usage:
//!   find . -name "*.bluebook" | hecks-life --batch train > training.jsonl

use crate::ir::Domain;

/// Extract one JSONL training pair from a parsed domain.
/// Prompt: "Conceive a domain for: {vision}"
/// Completion: the bluebook structure as a compact declaration.
pub fn extract_pair(domain: &Domain) -> String {
    let vision = domain.vision.as_deref().unwrap_or(&domain.name);
    let prompt = format!("Conceive a domain for: {}", vision);
    let completion = domain_to_declaration(domain);

    // Escape for JSON
    let prompt_esc = json_escape(&prompt);
    let completion_esc = json_escape(&completion);

    format!(
        r#"{{"prompt":"{}","completion":"{}","domain":"{}","aggregates":{},"commands":{},"policies":{}}}"#,
        prompt_esc,
        completion_esc,
        json_escape(&domain.name),
        domain.aggregates.len(),
        domain.aggregates.iter().map(|a| a.commands.len()).sum::<usize>(),
        domain.policies.len(),
    )
}

/// Render a domain as a compact bluebook declaration (the completion).
fn domain_to_declaration(domain: &Domain) -> String {
    let mut lines = Vec::new();

    for agg in &domain.aggregates {
        lines.push(format!("aggregate \"{}\"", agg.name));
        if let Some(ref desc) = agg.description {
            lines.push(format!("  description \"{}\"", desc));
        }
        for attr in &agg.attributes {
            let t = if attr.list { format!("list_of({})", attr.attr_type) } else { attr.attr_type.clone() };
            lines.push(format!("  {} :{}", t, attr.name));
        }
        for r in &agg.references {
            if let Some(ref d) = r.domain {
                lines.push(format!("  reference_to({}::{})", d, r.target));
            } else {
                lines.push(format!("  reference_to({})", r.target));
            }
        }
        for vo in &agg.value_objects {
            lines.push(format!("  value_object \"{}\"", vo.name));
            for attr in &vo.attributes {
                let t = if attr.list { format!("list_of({})", attr.attr_type) } else { attr.attr_type.clone() };
                lines.push(format!("    {} :{}", t, attr.name));
            }
        }
        for cmd in &agg.commands {
            lines.push(format!("  {}", cmd.name));
            if let Some(ref desc) = cmd.description {
                lines.push(format!("    description \"{}\"", desc));
            }
            for attr in &cmd.attributes {
                let t = if attr.list { format!("list_of({})", attr.attr_type) } else { attr.attr_type.clone() };
                lines.push(format!("    {} :{}", t, attr.name));
            }
            for r in &cmd.references {
                if let Some(ref d) = r.domain {
                    lines.push(format!("    reference_to({}::{})", d, r.target));
                } else {
                    lines.push(format!("    reference_to({})", r.target));
                }
            }
            if let Some(ref event) = cmd.emits {
                lines.push(format!("    emits \"{}\"", event));
            }
            for g in &cmd.givens {
                let text = g.message.as_deref().unwrap_or(&g.expression);
                lines.push(format!("    given \"{}\"", text));
            }
        }
    }

    for p in &domain.policies {
        lines.push(format!("policy \"{}\" on \"{}\" trigger \"{}\"", p.name, p.on_event, p.trigger_command));
    }

    lines.join("\n")
}

fn json_escape(s: &str) -> String {
    s.replace('\\', "\\\\")
     .replace('"', "\\\"")
     .replace('\n', "\\n")
     .replace('\r', "\\r")
     .replace('\t', "\\t")
}
