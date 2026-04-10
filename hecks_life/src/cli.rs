//! CLI router — dispatches ARGV to command handlers
//!
//! Reads cli.bluebook, builds a command registry from aggregates,
//! and routes the first argument to the matching handler.
//!
//!   hecks validate pizzas.bluebook
//!   hecks inspect pizzas.bluebook
//!   hecks tree pizzas.bluebook
//!   hecks help
//!   hecks version

use crate::ir::Domain;
use crate::parser;
use std::collections::HashMap;

/// A CLI command derived from a Bluebook aggregate.
pub struct CommandEntry {
    pub name: String,
    pub description: String,
    pub options: Vec<OptionDef>,
}

/// An option derived from a command's attributes.
pub struct OptionDef {
    pub name: String,
    pub attr_type: String,
}

/// Parsed ARGV for a matched command.
#[derive(Debug)]
pub struct Invocation {
    pub command: String,
    pub args: Vec<String>,
    pub options: HashMap<String, String>,
}

/// Build the command registry from the CLI domain IR.
pub fn build_registry(domain: &Domain) -> Vec<CommandEntry> {
    domain
        .aggregates
        .iter()
        .filter(|agg| agg.name.ends_with("Command"))
        .map(|agg| {
            let cli_name = to_cli_name(&agg.name);
            let options = agg
                .commands
                .first()
                .map(|cmd| {
                    cmd.attributes
                        .iter()
                        .map(|attr| OptionDef {
                            name: attr.name.clone(),
                            attr_type: attr.attr_type.clone(),
                        })
                        .collect()
                })
                .unwrap_or_default();

            CommandEntry {
                name: cli_name,
                description: agg.description.clone().unwrap_or_default(),
                options,
            }
        })
        .collect()
}

/// Parse ARGV against the registry. Returns the matched invocation.
pub fn parse_argv(argv: &[String], registry: &[CommandEntry]) -> Result<Invocation, String> {
    if argv.is_empty() {
        return Err("no command given".into());
    }

    let cmd_name = &argv[0];
    let _entry = registry
        .iter()
        .find(|e| e.name == *cmd_name)
        .ok_or_else(|| format!("unknown command: {}", cmd_name))?;

    let mut args = Vec::new();
    let mut options = HashMap::new();
    let mut i = 1;

    while i < argv.len() {
        if argv[i].starts_with("--") {
            let key = argv[i][2..].to_string();
            if i + 1 < argv.len() && !argv[i + 1].starts_with("--") {
                options.insert(key, argv[i + 1].clone());
                i += 2;
            } else {
                options.insert(key, "true".into());
                i += 1;
            }
        } else {
            args.push(argv[i].clone());
            i += 1;
        }
    }

    Ok(Invocation {
        command: cmd_name.clone(),
        args,
        options,
    })
}

/// Print grouped help.
pub fn print_help(registry: &[CommandEntry]) {
    println!("hecks — the domain compiler\n");
    println!("Usage: hecks <command> [options] [args]\n");
    println!("Commands:");
    let max_len = registry.iter().map(|e| e.name.len()).max().unwrap_or(20);
    for entry in registry {
        println!("  {:width$}  {}", entry.name, entry.description, width = max_len);
    }
    println!();
    println!("Run `hecks help <command>` for details on a specific command.");
}

/// Print help for a single command.
pub fn print_command_help(entry: &CommandEntry) {
    println!("hecks {} — {}\n", entry.name, entry.description);
    if entry.options.is_empty() {
        println!("  No options.");
    } else {
        println!("Options:");
        for opt in &entry.options {
            println!("  --{:20} {}", opt.name, opt.attr_type);
        }
    }
}

/// Print version.
pub fn print_version() {
    println!("hecks {}", env!("CARGO_PKG_VERSION"));
}

/// Derive CLI command name from aggregate name.
/// "BuildCommand" -> "build", "GenerateConfigCommand" -> "generate_config"
fn to_cli_name(aggregate_name: &str) -> String {
    let base = aggregate_name.strip_suffix("Command").unwrap_or(aggregate_name);
    to_snake_case(base)
}

fn to_snake_case(s: &str) -> String {
    let mut result = String::new();
    for (i, c) in s.chars().enumerate() {
        if c.is_uppercase() && i > 0 {
            result.push('_');
        }
        result.push(c.to_lowercase().next().unwrap());
    }
    result
}

/// Load the CLI domain from a bluebook file.
pub fn load_cli_domain(path: &str) -> Domain {
    let source = std::fs::read_to_string(path).unwrap_or_else(|e| {
        eprintln!("Cannot read CLI bluebook {}: {}", path, e);
        std::process::exit(1);
    });
    parser::parse(&source)
}
