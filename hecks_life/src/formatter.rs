//! Domain formatter — terminal display of parsed domains
//!
//! Ports the Ruby DomainInspector to Rust. Three views:
//! inspect (full detail), tree (hierarchy), list (summary).
//!
//! Usage:
//!   formatter::inspect(&domain);
//!   formatter::tree(&domain);
//!   formatter::list(&domain);

use crate::ir::{Domain, Aggregate, MutationOp};

/// Full inspection: every aggregate with attributes, commands, behavior, lifecycle.
pub fn inspect(domain: &Domain) {
    let header = format!("Domain: {}", domain.name);
    println!("{}", header);
    println!("{}", "=".repeat(header.len()));
    println!();

    for agg in &domain.aggregates {
        inspect_aggregate(agg);
        println!();
    }

    if !domain.policies.is_empty() {
        println!("Domain Policies:");
        for pol in &domain.policies {
            if let Some(ref target) = pol.target_domain {
                println!("  {}: {} -> {}:{}", pol.name, pol.on_event, target, pol.trigger_command);
            } else {
                println!("  {}: {} -> {}", pol.name, pol.on_event, pol.trigger_command);
            }
        }
        println!();
    }

    if !domain.vows.is_empty() {
        println!("Vows:");
        for vow in &domain.vows {
            println!("  {} — {}", vow.name, vow.text);
        }
        println!();
    }
}

fn inspect_aggregate(agg: &Aggregate) {
    println!("  {}", agg.name);
    if let Some(ref desc) = agg.description {
        println!("    {}", desc);
    }
    println!();

    if !agg.attributes.is_empty() {
        println!("    Attributes:");
        for attr in &agg.attributes {
            let list_tag = if attr.list { " (list)" } else { "" };
            let default_tag = attr
                .default
                .as_ref()
                .map(|d| format!(" = {}", d))
                .unwrap_or_default();
            println!(
                "      {} : {}{}{}",
                attr.name, attr.attr_type, list_tag, default_tag
            );
        }
    }

    if !agg.references.is_empty() {
        println!("    References:");
        for r in &agg.references {
            let domain_tag = r
                .domain
                .as_ref()
                .map(|d| format!(" ({})", d))
                .unwrap_or_default();
            println!("      -> {}{}", r.target, domain_tag);
        }
    }

    if !agg.value_objects.is_empty() {
        println!("    Value Objects:");
        for vo in &agg.value_objects {
            let attrs: Vec<String> = vo
                .attributes
                .iter()
                .map(|a| format!("{}: {}", a.name, a.attr_type))
                .collect();
            println!("      {} ({})", vo.name, attrs.join(", "));
        }
    }

    if !agg.commands.is_empty() {
        println!("    Commands:");
        for cmd in &agg.commands {
            let role_tag = cmd
                .role
                .as_ref()
                .map(|r| format!(" [{}]", r))
                .unwrap_or_default();
            let emits_tag = cmd
                .emits
                .as_ref()
                .map(|e| format!(" -> {}", e))
                .unwrap_or_default();
            println!("      {}{}{}", cmd.name, role_tag, emits_tag);

            for attr in &cmd.attributes {
                println!("        attr: {} : {}", attr.name, attr.attr_type);
            }
            for r in &cmd.references {
                println!("        ref: -> {}", r.target);
            }
            for given in &cmd.givens {
                let msg = given
                    .message
                    .as_ref()
                    .map(|m| format!(" \"{}\"", m))
                    .unwrap_or_default();
                println!("        given{} {{ {} }}", msg, given.expression);
            }
            for mutation in &cmd.mutations {
                let op = match mutation.operation {
                    MutationOp::Set => "set",
                    MutationOp::Append => "append",
                    MutationOp::Increment => "increment",
                    MutationOp::Decrement => "decrement",
                    MutationOp::Toggle => "toggle",
                };
                println!(
                    "        then_{} :{} {}",
                    op, mutation.field, mutation.value
                );
            }
        }
    }

    if let Some(ref lc) = agg.lifecycle {
        println!("    Lifecycle: :{} (default: {})", lc.field, lc.default);
        for t in &lc.transitions {
            let from = t
                .from_state
                .as_ref()
                .map(|f| format!(", from: \"{}\"", f))
                .unwrap_or_default();
            println!(
                "      {} => \"{}\"{}",
                t.command, t.to_state, from
            );
        }
    }
}

/// Tree view: compact hierarchy of aggregates and commands.
pub fn tree(domain: &Domain) {
    println!("{}", domain.name);
    let agg_count = domain.aggregates.len();
    for (i, agg) in domain.aggregates.iter().enumerate() {
        let is_last_agg = i == agg_count - 1;
        let branch = if is_last_agg { "└──" } else { "├──" };
        let desc = agg
            .description
            .as_ref()
            .map(|d| format!(" — {}", d))
            .unwrap_or_default();
        println!("{} {}{}", branch, agg.name, desc);

        let prefix = if is_last_agg { "    " } else { "│   " };
        let cmd_count = agg.commands.len();
        for (j, cmd) in agg.commands.iter().enumerate() {
            let is_last_cmd = j == cmd_count - 1;
            let cmd_branch = if is_last_cmd { "└──" } else { "├──" };
            let emits = cmd
                .emits
                .as_ref()
                .map(|e| format!(" -> {}", e))
                .unwrap_or_default();
            println!("{}{} {}{}", prefix, cmd_branch, cmd.name, emits);
        }
    }

    if !domain.policies.is_empty() {
        println!("Policies:");
        for pol in &domain.policies {
            println!("  {} : {} -> {}", pol.name, pol.on_event, pol.trigger_command);
        }
    }
}

/// List view: summary counts.
pub fn list(domain: &Domain) {
    println!("{} — {} aggregate(s), {} policy(ies)",
        domain.name,
        domain.aggregates.len(),
        domain.policies.len(),
    );
    println!();

    for agg in &domain.aggregates {
        let cmd_names: Vec<&str> = agg.commands.iter().map(|c| c.name.as_str()).collect();
        println!(
            "  {} ({} commands): {}",
            agg.name,
            cmd_names.len(),
            cmd_names.join(", ")
        );
    }
}
