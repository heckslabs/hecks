//! Domain Index — the compiled knowledge of every domain, aggregate, command
//!
//! Scans all bluebook directories, parses each one, and builds an
//! in-memory index. Autocomplete and execution work from this index.
//! No LLM needed — just the domain, fully navigable.
//!
//! Path format: Domain.Aggregate.Command param:value param:value
//!
//! Usage:
//!   let idx = DomainIndex::compile(project_dir);
//!   let completions = idx.complete("Book");
//!   let result = idx.execute("Bookshelf.Book.AddBook title:Dune", project_dir);

use hecks_life::parser;
use hecks_life::ir::{Domain, Aggregate, Command, Attribute};
use hecks_life::runtime::{Runtime, Value};
use std::collections::HashMap;
use std::fs;
use std::path::Path;

/// One entry in the index: a command with its full path and parameters.
#[derive(Debug, Clone)]
pub struct IndexEntry {
    pub domain: String,
    pub aggregate: String,
    pub command: String,
    pub params: Vec<ParamInfo>,
    pub description: String,
}

#[derive(Debug, Clone)]
pub struct ParamInfo {
    pub name: String,
    pub param_type: String,
    pub required: bool,
}

pub struct DomainIndex {
    /// All indexed entries, keyed by "Domain.Aggregate.Command"
    entries: Vec<IndexEntry>,
    /// All domain names
    domains: Vec<String>,
    /// Domain.Aggregate paths
    aggregates: Vec<String>,
    /// Full command paths
    commands: Vec<String>,
    /// Parsed domains for execution
    parsed: HashMap<String, Domain>,
}

impl DomainIndex {
    /// Compile the index from all bluebook directories.
    pub fn compile(project_dir: &str) -> Self {
        let project = Path::new(project_dir);
        let dirs = ["aggregates", "nursery", "catalog", "capabilities"];

        let mut entries = Vec::new();
        let mut domains = Vec::new();
        let mut aggregates = Vec::new();
        let mut commands = Vec::new();
        let mut parsed = HashMap::new();

        for dir_name in &dirs {
            let dir = project.join(dir_name);
            if !dir.is_dir() { continue; }
            scan_dir(&dir, &mut entries, &mut domains, &mut aggregates, &mut commands, &mut parsed);
        }

        domains.sort();
        domains.dedup();
        aggregates.sort();
        aggregates.dedup();
        commands.sort();

        DomainIndex { entries, domains, aggregates, commands, parsed }
    }

    pub fn domain_count(&self) -> usize { self.domains.len() }
    pub fn aggregate_count(&self) -> usize { self.aggregates.len() }
    pub fn command_count(&self) -> usize { self.commands.len() }

    /// Autocomplete — returns matching paths for the given prefix.
    /// Completes at every level: domains, aggregates, commands, params.
    pub fn complete(&self, prefix: &str) -> Vec<String> {
        let lower = prefix.to_lowercase();
        let parts: Vec<&str> = prefix.split('.').collect();

        match parts.len() {
            // No dot yet — complete domain names
            1 => {
                let mut results: Vec<String> = self.domains.iter()
                    .filter(|d| d.to_lowercase().starts_with(&lower))
                    .cloned()
                    .collect();
                // Also match aggregates and commands directly
                for entry in &self.entries {
                    let agg_lower = entry.aggregate.to_lowercase();
                    let cmd_lower = entry.command.to_lowercase();
                    if agg_lower.starts_with(&lower) {
                        let path = format!("{}.{}", entry.domain, entry.aggregate);
                        if !results.contains(&path) { results.push(path); }
                    }
                    if cmd_lower.starts_with(&lower) {
                        let path = format!("{}.{}.{}", entry.domain, entry.aggregate, entry.command);
                        if !results.contains(&path) { results.push(path); }
                    }
                }
                results.truncate(20);
                results
            }
            // One dot — complete aggregate names within domain
            2 => {
                let domain = parts[0];
                let agg_prefix = parts[1].to_lowercase();
                self.aggregates.iter()
                    .filter(|a| {
                        a.to_lowercase().starts_with(&format!("{}.", domain.to_lowercase()))
                    })
                    .filter(|a| {
                        let agg_part = a.split('.').nth(1).unwrap_or("");
                        agg_part.to_lowercase().starts_with(&agg_prefix)
                    })
                    .cloned()
                    .take(20)
                    .collect()
            }
            // Two dots — complete command names within aggregate
            3 => {
                let domain = parts[0];
                let agg = parts[1];
                let cmd_prefix = parts[2].to_lowercase();
                let path_prefix = format!("{}.{}.", domain, agg).to_lowercase();
                let mut results: Vec<String> = self.commands.iter()
                    .filter(|c| c.to_lowercase().starts_with(&path_prefix))
                    .filter(|c| {
                        let cmd_part = c.split('.').nth(2).unwrap_or("");
                        cmd_part.to_lowercase().starts_with(&cmd_prefix)
                    })
                    .cloned()
                    .take(20)
                    .collect();
                // If exact command match, show params
                if results.len() == 1 || (cmd_prefix.len() > 0 && results.iter().any(|r| {
                    r.split('.').nth(2).unwrap_or("").to_lowercase() == cmd_prefix
                })) {
                    let full = format!("{}.{}.{}", domain, agg, parts[2]);
                    if let Some(entry) = self.entries.iter().find(|e|
                        format!("{}.{}.{}", e.domain, e.aggregate, e.command).to_lowercase() == full.to_lowercase()
                    ) {
                        results.clear();
                        for p in &entry.params {
                            results.push(format!("{} {}:", full, p.name));
                        }
                    }
                }
                results
            }
            _ => Vec::new(),
        }
    }

    /// Execute a command string: "Domain.Aggregate.Command param:value param:value"
    pub fn execute(&mut self, input: &str, project_dir: &str) -> String {
        let parts: Vec<&str> = input.splitn(2, ' ').collect();
        let path = parts[0];
        let param_str = if parts.len() > 1 { parts[1] } else { "" };

        let path_parts: Vec<&str> = path.split('.').collect();
        if path_parts.len() < 3 {
            return format!("Usage: Domain.Aggregate.Command param:value\nGot: {}", path);
        }

        let domain_name = path_parts[0];
        let agg_name = path_parts[1];
        let cmd_name = path_parts[2];

        // Find the entry
        let entry = match self.entries.iter().find(|e|
            e.domain.to_lowercase() == domain_name.to_lowercase() &&
            e.aggregate.to_lowercase() == agg_name.to_lowercase() &&
            e.command.to_lowercase() == cmd_name.to_lowercase()
        ) {
            Some(e) => e,
            None => return format!("Not found: {}", path),
        };

        // Parse parameters
        let params = parse_params(param_str);

        // Execute via runtime
        let domain = match self.parsed.get(&entry.domain) {
            Some(d) => d,
            None => return format!("Domain not loaded: {}", entry.domain),
        };

        // Boot the runtime for this domain and dispatch
        let domain = match self.parsed.remove(&entry.domain) {
            Some(d) => d,
            None => return format!("Domain not loaded: {}", entry.domain),
        };
        let data_dir = Some(format!("{}/information", project_dir));
        let mut rt = Runtime::boot_with_data_dir(domain, data_dir);

        // Convert params to runtime Values
        let attrs: HashMap<String, Value> = params.iter()
            .map(|(k, v)| (k.clone(), Value::Str(v.clone())))
            .collect();

        // Dispatch
        let mut output = String::new();
        match rt.dispatch(&entry.command, attrs) {
            Ok(result) => {
                // Show the event chain
                if let Some(ref event) = result.event {
                    output.push_str(&format!("  \x1b[33m⚡\x1b[0m {}\n", event.name));
                    output.push_str(&format!("    aggregate: {}\n", result.aggregate_type));
                    output.push_str(&format!("    id: {}\n", result.aggregate_id));
                    for (k, v) in &event.data {
                        let display = match v {
                            Value::Str(s) => s.clone(),
                            Value::Int(n) => n.to_string(),
                            Value::Bool(b) => b.to_string(),
                            Value::Null => "null".into(),
                            _ => format!("{:?}", v),
                        };
                        output.push_str(&format!("    {}: {}\n", k, display));
                    }
                }
                // Show any policy-triggered events from the event bus
                let events = rt.event_bus.events();
                // Skip the first event (already shown above)
                for event in events.iter().skip(1) {
                    output.push_str(&format!("  \x1b[33m⚡\x1b[0m {} \x1b[2m(policy)\x1b[0m\n", event.name));
                    for (k, v) in &event.data {
                        let display = match v {
                            Value::Str(s) => s.clone(),
                            Value::Int(n) => n.to_string(),
                            Value::Bool(b) => b.to_string(),
                            Value::Null => "null".into(),
                            _ => format!("{:?}", v),
                        };
                        output.push_str(&format!("    {}: {}\n", k, display));
                    }
                }
            }
            Err(e) => {
                output.push_str(&format!("  \x1b[31m✗\x1b[0m {}\n", e));
            }
        }

        // Put domain back
        // (can't — we moved it. That's fine, exec is one-shot)

        output
    }

    /// Print the full domain tree.
    pub fn print_tree(&self) {
        let mut current_domain = String::new();
        let mut current_agg = String::new();

        for entry in &self.entries {
            if entry.domain != current_domain {
                current_domain = entry.domain.clone();
                current_agg.clear();
                println!("\x1b[33m{}\x1b[0m", entry.domain);
            }
            if entry.aggregate != current_agg {
                current_agg = entry.aggregate.clone();
                println!("  \x1b[36m{}\x1b[0m", entry.aggregate);
            }
            let params: Vec<String> = entry.params.iter()
                .map(|p| format!("{}:{}", p.name, short_type(&p.param_type)))
                .collect();
            let param_str = if params.is_empty() { String::new() }
                else { format!(" \x1b[2m{}\x1b[0m", params.join(" ")) };
            println!("    {}{}", entry.command, param_str);
        }
    }
}

/// Scan a directory for .bluebook files (recursively for nursery subdirs).
fn scan_dir(
    dir: &Path,
    entries: &mut Vec<IndexEntry>,
    domains: &mut Vec<String>,
    aggregates: &mut Vec<String>,
    commands: &mut Vec<String>,
    parsed: &mut HashMap<String, Domain>,
) {
    let read = match fs::read_dir(dir) {
        Ok(r) => r,
        Err(_) => return,
    };

    for item in read.filter_map(|e| e.ok()) {
        let path = item.path();
        if path.is_dir() {
            // Recurse into subdirectories (nursery/project/hecks/)
            scan_dir(&path, entries, domains, aggregates, commands, parsed);
        } else if path.extension().map_or(false, |ext| ext == "bluebook") {
            // Skip very large files to keep indexing fast
            let size = fs::metadata(&path).map(|m| m.len()).unwrap_or(0);
            if size > 200_000 { continue; } // skip >200KB
            if let Ok(source) = fs::read_to_string(&path) {
                let domain = parser::parse(&source);
                let dname = domain.name.clone();

                if !domains.contains(&dname) {
                    domains.push(dname.clone());
                }

                for agg in &domain.aggregates {
                    let agg_path = format!("{}.{}", dname, agg.name);
                    if !aggregates.contains(&agg_path) {
                        aggregates.push(agg_path);
                    }

                    for cmd in &agg.commands {
                        let cmd_path = format!("{}.{}.{}", dname, agg.name, cmd.name);
                        commands.push(cmd_path);

                        let params: Vec<ParamInfo> = cmd.attributes.iter()
                            .map(|a| ParamInfo {
                                name: a.name.clone(),
                                param_type: a.attr_type.clone(),
                                required: a.name == "title" || a.name == "name",
                            })
                            .collect();

                        entries.push(IndexEntry {
                            domain: dname.clone(),
                            aggregate: agg.name.clone(),
                            command: cmd.name.clone(),
                            params,
                            description: cmd.description.clone().unwrap_or_default(),
                        });
                    }
                }

                parsed.insert(dname, domain);
            }
        }
    }
}

fn parse_params(input: &str) -> HashMap<String, String> {
    let mut params = HashMap::new();
    // Parse "key:value key:\"multi word\"" format
    let mut remaining = input.trim();
    while !remaining.is_empty() {
        if let Some(colon) = remaining.find(':') {
            let key = remaining[..colon].trim().to_string();
            remaining = &remaining[colon + 1..];
            let value;
            if remaining.starts_with('"') {
                // Quoted value
                remaining = &remaining[1..];
                if let Some(end) = remaining.find('"') {
                    value = remaining[..end].to_string();
                    remaining = remaining[end + 1..].trim_start();
                } else {
                    value = remaining.to_string();
                    remaining = "";
                }
            } else {
                // Unquoted — up to next space
                if let Some(space) = remaining.find(' ') {
                    value = remaining[..space].to_string();
                    remaining = remaining[space + 1..].trim_start();
                } else {
                    value = remaining.to_string();
                    remaining = "";
                }
            }
            params.insert(key, value);
        } else {
            break;
        }
    }
    params
}

fn short_type(t: &str) -> &str {
    match t {
        "String" => "str",
        "Integer" => "int",
        "Float" => "float",
        "Boolean" => "bool",
        "Date" => "date",
        _ => t,
    }
}
