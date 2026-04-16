//! Hecks Life — the Bluebook compiler and runtime
//!
//! Reads .bluebook files, parses them into IR, and executes them.
//! The Bluebook is DNA. This is the ribosome. The runtime is life.
//!
//! Usage:
//!   hecks-life parse     pizzas.bluebook
//!   hecks-life validate  pizzas.bluebook
//!   hecks-life inspect   pizzas.bluebook
//!   hecks-life tree      pizzas.bluebook
//!   hecks-life list      pizzas.bluebook
//!   hecks-life run       pizzas.bluebook [--seed seeds.txt]
//!   hecks-life serve     pizzas.bluebook [--seed seeds.txt] [port]
//!   hecks-life serve     path/to/hecks/ [port]
//!   hecks-life conceive  "Name" "vision" --corpus dir1 dir2
//!   hecks-life develop   target.bluebook --add "feature"

use hecks_life::{parser, formatter, validator, validator_warnings, server, repl, conceiver, heki, boot, daemon, tongue, lexicon, terminal, project, training};
use hecks_life::runtime::Runtime;

use std::env;
use std::fs;

fn main() {
    let args: Vec<String> = env::args().collect();

    // Detect being name from argv[0]: "miette" -> "Miette", "summer" -> "Summer"
    let being = being_from_argv0(&args[0]);

    // Named beings (winter/summer) with no subcommand go straight to terminal
    let is_named = std::path::Path::new(&args[0]).file_name()
        .map_or(false, |n| n == "winter" || n == "summer");

    if args.len() < 2 {
        if is_named {
            let dir = resolve_home(&being);
            terminal::run(&dir, &being);
            return;
        }
        print_usage();
        std::process::exit(1);
    }

    // Backwards compat: if arg[1] is a file path, treat as parse
    let (command, path) = if args.len() == 2 && args[1].contains('.') {
        ("parse", args[1].as_str())
    } else if args.len() >= 3 {
        (args[1].as_str(), args[2].as_str())
    } else {
        (args[1].as_str(), "")
    };

    if command == "help" || command == "--help" {
        print_usage();
        return;
    }

    // Heki commands — .heki binary store operations
    if command == "hydrate" {
        let dir = if path.is_empty() { "information" } else { path };
        match heki::read_dir(dir) {
            Ok(stores) => heki::print_summary(&stores),
            Err(e) => { eprintln!("hydrate error: {}", e); std::process::exit(1); }
        }
        return;
    }

    // Lexicon commands — compile and query the vocabulary
    if command == "lexicon" {
        let dir = if !path.is_empty() {
            path.to_string()
        } else {
            resolve_home(&being)
        };
        let query = args.get(3).map(|s| s.as_str());
        let lex = lexicon::Lexicon::compile(&dir);
        if let Some(input) = query {
            match lex.match_input(input) {
                Some(m) => {
                    let path: Vec<String> = m.path.iter()
                        .map(|r| format!("[{}] {}::{}::{}", r.location, r.domain, r.aggregate, r.command))
                        .collect();
                    println!("  {:?} match ({:.0}%): {}", m.strategy, m.confidence * 100.0, m.matched_phrase);
                    println!("  → {}", path.join(" → "));
                    for r in &m.path {
                        if !r.domain_vision.is_empty() {
                            println!("  vision: {}", r.domain_vision);
                        }
                        if !r.aggregate_desc.is_empty() {
                            println!("  aggregate: {} — {}", r.aggregate, r.aggregate_desc);
                        }
                        if !r.command_goal.is_empty() {
                            println!("  goal: {}", r.command_goal);
                        }
                    }
                }
                None => println!("  no match"),
            }
        } else {
            lex.dump();
        }
        return;
    }

    if command == "terminal" {
        let dir = if !path.is_empty() {
            path.to_string()
        } else {
            resolve_home(&being)
        };
        terminal::run(&dir, &being);
        return;
    }

    if command == "speak" {
        let dir = if args.len() > 3 { args[3].as_str() } else { "." };
        let ctx = daemon::DaemonCtx::new(dir);
        // Pulse now fires via bluebook dispatch
        // Then speak
        if let Some(response) = tongue::speak(&ctx, path) {
            println!("{}", response);
        } else {
            eprintln!("tongue: could not reach language center (is ollama running?)");
        }
        return;
    }

    if command == "status" || command == "musings" {
        eprintln!("status and musings now read from heki directly:");
        eprintln!("  hecks-life heki latest information/heartbeat.heki");
        eprintln!("  hecks-life heki latest information/consciousness.heki");
        eprintln!("  hecks-life heki latest information/mood.heki");
        eprintln!("  hecks-life heki read information/musing.heki");
        return;
    }

    if command == "boot" {
        let dir = if !path.is_empty() {
            path.to_string()
        } else {
            resolve_home(&being)
        };
        let show_nerves = args.iter().any(|a| a == "--nerves");
        boot::run(&dir, show_nerves, &being);
        return;
    }

    if command == "daemon" {
        run_daemon(&args);
        return;
    }

    if command == "heki" {
        run_heki(&args);
        return;
    }

    if command == "conceive" {
        conceiver::commands::run_conceive(&args);
        return;
    }

    if command == "develop" {
        conceiver::commands::run_develop(&args);
        return;
    }

    // Batch mode: read file paths from stdin, process each
    if path == "--batch" {
        run_batch(command);
        return;
    }

    // Bluebook dispatch: hecks-life <dir-or-file> <CommandName>
    // If first arg is a directory/bluebook and second is a PascalCase command, dispatch it
    // Bluebook dispatch: hecks-life <dir-or-file> Aggregate.Command
    // e.g. hecks-life aggregates/ Heartbeat.Beat
    if !path.is_empty()
        && path.contains('.')
        && path.chars().next().map_or(false, |c| c.is_uppercase())
        && (std::path::Path::new(command).is_dir()
            || command.ends_with(".bluebook"))
    {
        let target = command;
        let cmd_name = path.split('.').last().unwrap_or(path);
        if std::path::Path::new(target).is_dir() {
            dispatch_hecksagon(target, cmd_name);
        } else {
            let source = fs::read_to_string(target).unwrap_or_else(|e| {
                eprintln!("Cannot read {}: {}", target, e);
                std::process::exit(1);
            });
            let domain = parser::parse(&source);
            let data_dir = find_world_heki_dir(target)
                .unwrap_or_else(|| format!("{}/data", std::path::Path::new(target).parent()
                    .unwrap_or(std::path::Path::new(".")).display()));
            let mut rt = Runtime::boot_with_data_dir(domain, Some(data_dir));
            match rt.dispatch(cmd_name, std::collections::HashMap::new()) {
                Ok(result) => println!("{}", serde_json::json!({
                    "ok": true, "aggregate": result.aggregate_type, "id": result.aggregate_id,
                })),
                Err(e) => { eprintln!("dispatch error: {:?}", e); std::process::exit(1); }
            }
        }
        return;
    }

    if path.is_empty() {
        eprintln!("Usage: hecks-life {} <bluebook-file-or-dir>", command);
        std::process::exit(1);
    }

    // Multi-domain: if path is a directory, load all bluebooks
    if (command == "serve" || command == "run") && std::path::Path::new(path).is_dir() {
        if command == "run" {
            // --dispatch CommandName: fire across all loaded domains
            let dispatch_cmd = args.iter().position(|a| a == "--dispatch")
                .and_then(|i| args.get(i + 1))
                .map(|s| s.to_string());
            if let Some(cmd_name) = dispatch_cmd {
                // Read data dir from world.hec (sibling or parent of aggregates dir)
                let data_dir = find_world_heki_dir(path)
                    .unwrap_or_else(|| format!("{}/data", path.trim_end_matches('/')));
                // Merge all bluebooks into one combined domain
                let mut combined = hecks_life::ir::Domain {
                    name: "Hecksagon".into(),
                    category: None, vision: None,
                    aggregates: vec![], policies: vec![],
                    fixtures: vec![], vows: vec![],
                };
                let entries = fs::read_dir(path).unwrap_or_else(|e| {
                    eprintln!("Cannot read directory {}: {}", path, e);
                    std::process::exit(1);
                });
                for entry in entries.flatten() {
                    let p = entry.path();
                    if p.extension().map(|e| e == "bluebook").unwrap_or(false) {
                        if let Ok(source) = fs::read_to_string(&p) {
                            let domain = parser::parse(&source);
                            combined.aggregates.extend(domain.aggregates);
                            combined.policies.extend(domain.policies);
                            combined.fixtures.extend(domain.fixtures);
                        }
                    }
                }
                let mut rt = Runtime::boot_with_data_dir(
                    combined, Some(data_dir));
                match rt.dispatch(&cmd_name, std::collections::HashMap::new()) {
                    Ok(result) => {
                        println!("{}", serde_json::json!({
                            "ok": true,
                            "aggregate": result.aggregate_type,
                            "id": result.aggregate_id,
                        }));
                    }
                    Err(e) => {
                        eprintln!("dispatch error: {:?}", e);
                        std::process::exit(1);
                    }
                }
                return;
            }
        }
    }
    if command == "serve" && std::path::Path::new(path).is_dir() {
        let port: u16 = args.iter().find(|a| a.parse::<u16>().is_ok())
            .and_then(|s| s.parse().ok()).unwrap_or(3100);
        server::multi::serve_directory(path, port);
        return;
    }

    let source = fs::read_to_string(path).unwrap_or_else(|e| {
        eprintln!("Cannot read {}: {}", path, e);
        std::process::exit(1);
    });

    let domain = parser::parse(&source);

    let seed_path = args.iter().position(|a| a == "--seed")
        .and_then(|i| args.get(i + 1))
        .map(|s| s.as_str());

    match command {
        "parse" => println!("{}", domain),
        "validate" => {
            let errors = validator::validate(&domain);
            if errors.is_empty() {
                let warns = validator_warnings::warnings(&domain);
                for w in &warns { println!("  WARNING: {}", w); }
                println!("VALID — {} ({} aggregates)", domain.name, domain.aggregates.len());
            } else {
                println!("INVALID — {} errors:", errors.len());
                for err in &errors { println!("  {}", err); }
                std::process::exit(1);
            }
        }
        "inspect" => formatter::inspect(&domain),
        "tree" => formatter::tree(&domain),
        "list" => formatter::list(&domain),
        "project" => print!("{}", project::project(&domain)),
        "counts" => {
            let cmds: usize = domain.aggregates.iter().map(|a| a.commands.len()).sum();
            println!("{}|{}|{}|{}|{}", domain.name, domain.aggregates.len(), cmds, domain.policies.len(), domain.fixtures.len());
        }
        "train" => {
            println!("{}", training::extract_pair(&domain));
        }
        "run" => {
            let mut rt = Runtime::boot(domain);
            load_seeds(&mut rt, seed_path);
            // --dispatch CommandName: fire one command, drain policies, exit
            let dispatch_cmd = args.iter().position(|a| a == "--dispatch")
                .and_then(|i| args.get(i + 1))
                .map(|s| s.as_str());
            if let Some(cmd_name) = dispatch_cmd {
                let attrs = std::collections::HashMap::new();
                match rt.dispatch(cmd_name, attrs) {
                    Ok(result) => {
                        println!("{}", serde_json::json!({
                            "ok": true,
                            "aggregate": result.aggregate_type,
                            "id": result.aggregate_id,
                        }));
                    }
                    Err(e) => {
                        eprintln!("dispatch error: {:?}", e);
                        std::process::exit(1);
                    }
                }
            } else {
                repl::run(rt);
            }
        }
        "serve" => {
            let port: u16 = args.iter().find(|a| a.parse::<u16>().is_ok())
                .and_then(|s| s.parse().ok()).unwrap_or(3100);
            let mut rt = Runtime::boot(domain);
            load_seeds(&mut rt, seed_path);
            server::serve(rt, port);
        }
        _ => {
            eprintln!("Unknown command: {}", command);
            print_usage();
            std::process::exit(1);
        }
    }
}

fn run_batch(command: &str) {
    use std::io::{self, BufRead};
    let stdin = io::stdin();
    let (mut valid, mut invalid, mut total) = (0, 0, 0);

    for line in stdin.lock().lines() {
        let file_path = match line {
            Ok(l) => l.trim().to_string(),
            Err(_) => continue,
        };
        if file_path.is_empty() { continue; }
        total += 1;

        let source = match fs::read_to_string(&file_path) {
            Ok(s) => s,
            Err(e) => { eprintln!("ERROR|{}|{}", file_path, e); invalid += 1; continue; }
        };

        let domain = parser::parse(&source);
        match command {
            "validate" => {
                let errors = validator::validate(&domain);
                if errors.is_empty() {
                    let warns = validator_warnings::warnings(&domain);
                    for w in &warns { eprintln!("  WARNING: {}", w); }
                    println!("VALID|{}", file_path); valid += 1;
                }
                else { println!("INVALID|{}|{}", file_path, errors.join("; ")); invalid += 1; }
            }
            "counts" => {
                let cmds: usize = domain.aggregates.iter().map(|a| a.commands.len()).sum();
                println!("{}|{}|{}|{}|{}|{}", file_path, domain.name, domain.aggregates.len(), cmds, domain.policies.len(), domain.fixtures.len());
                valid += 1;
            }
            "train" => {
                let errors = validator::validate(&domain);
                if errors.is_empty() {
                    println!("{}", training::extract_pair(&domain));
                    valid += 1;
                } else {
                    invalid += 1;
                }
            }
            _ => { eprintln!("Batch mode only supports: validate, counts, train"); std::process::exit(1); }
        }
    }
    eprintln!("Batch: {} total, {} valid, {} invalid", total, valid, invalid);
    if invalid > 0 { std::process::exit(1); }
}

fn load_seeds(rt: &mut Runtime, seed_path: Option<&str>) {
    if let Some(path) = seed_path {
        match hecks_life::runtime::seed_loader::load(rt, path) {
            Ok(count) => eprintln!("  loaded {} seed commands from {}", count, path),
            Err(e) => eprintln!("  seed error: {}", e),
        }
    }
}

/// daemon subcommands: pulse, daydream, sleep
///   hecks-life daemon pulse    <project-dir> [carrying] [concept] [response]
///   hecks-life daemon daydream <project-dir>
///   hecks-life daemon sleep    <project-dir> [--nap] [--now]
fn run_daemon(args: &[String]) {
    if args.len() < 4 {
        eprintln!("Usage: hecks-life daemon <pulse|daydream|sleep> <project-dir> [args...]");
        std::process::exit(1);
    }
    let sub = args[2].as_str();
    let project_dir = args[3].as_str();
    let ctx = daemon::DaemonCtx::new(project_dir);

    match sub {
        "pulse" => {
            let carrying = args.get(4).map(|s| s.as_str()).unwrap_or("—");
            let concept = args.get(5).map(|s| s.as_str());
            let response = args.get(6).map(|s| s.as_str());
            eprintln!("pulse now fires via bluebook dispatch: hecks-life run aggregates/ --dispatch Beat");
        }
        "daydream" => eprintln!("daydream now runs via bluebook dispatch: hecks-life run aggregates/ --dispatch EnterDaydream"),
        "sleep" => eprintln!("sleep now runs via bluebook dispatch: hecks-life run aggregates/ --dispatch EnterSleep"),
        "mindstream" => eprintln!("mindstream now runs via ./mindstream.sh (bluebook dispatch loop)"),
        "greeting" => eprintln!("greeting now lives in greeting.bluebook — the hecksagon wires it to the tongue"),
        _ => {
            eprintln!("Unknown daemon: {}. Available: pulse, daydream, sleep", sub);
            std::process::exit(1);
        }
    }
}

/// heki subcommands: read, append, upsert, delete, latest
///   hecks-life heki read   <file.heki>
///   hecks-life heki append <file.heki> key=val key2=val2
///   hecks-life heki upsert <file.heki> key=val key2=val2
///   hecks-life heki delete <file.heki> <id>
///   hecks-life heki latest <file.heki>
fn run_heki(args: &[String]) {
    if args.len() < 4 {
        eprintln!("Usage: hecks-life heki <read|append|upsert|delete|latest> <file.heki> [args...]");
        std::process::exit(1);
    }

    let sub = args[2].as_str();
    let file = args[3].as_str();

    match sub {
        "read" => {
            match heki::read(file) {
                Ok(store) => {
                    let json = serde_json::to_string_pretty(&store).unwrap_or_default();
                    println!("{}", json);
                }
                Err(e) => { eprintln!("{}", e); std::process::exit(1); }
            }
        }
        "latest" => {
            match heki::read(file) {
                Ok(store) => {
                    if let Some(rec) = heki::latest(&store) {
                        let json = serde_json::to_string_pretty(rec).unwrap_or_default();
                        println!("{}", json);
                    } else {
                        println!("{{}}");
                    }
                }
                Err(e) => { eprintln!("{}", e); std::process::exit(1); }
            }
        }
        "append" => {
            let attrs = heki::parse_attrs(&args[4..]);
            match heki::append(file, &attrs) {
                Ok(rec) => {
                    let json = serde_json::to_string_pretty(&rec).unwrap_or_default();
                    println!("{}", json);
                }
                Err(e) => { eprintln!("{}", e); std::process::exit(1); }
            }
        }
        "upsert" => {
            let attrs = heki::parse_attrs(&args[4..]);
            match heki::upsert(file, &attrs) {
                Ok(rec) => {
                    let json = serde_json::to_string_pretty(&rec).unwrap_or_default();
                    println!("{}", json);
                }
                Err(e) => { eprintln!("{}", e); std::process::exit(1); }
            }
        }
        "delete" => {
            if args.len() < 5 {
                eprintln!("Usage: hecks-life heki delete <file.heki> <id>");
                std::process::exit(1);
            }
            let id = args[4].as_str();
            match heki::delete(file, id) {
                Ok(true) => println!("deleted {}", id),
                Ok(false) => { eprintln!("not found: {}", id); std::process::exit(1); }
                Err(e) => { eprintln!("{}", e); std::process::exit(1); }
            }
        }
        _ => {
            eprintln!("Unknown heki command: {}", sub);
            eprintln!("Available: read, append, upsert, delete, latest");
            std::process::exit(1);
        }
    }
}

/// Derive the being name from argv[0].
/// "miette" or "/path/to/miette" -> "Miette"
/// "summer" or "/path/to/summer" -> "Summer"
/// Anything else (hecks-life, etc) -> "Miette" (default)
fn being_from_argv0(argv0: &str) -> String {
    let bin = std::path::Path::new(argv0)
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("miette");
    match bin {
        "summer" => "Summer".into(),
        "miette" => "Miette".into(),
        _ => "Miette".into(),
    }
}

/// Find the heki dir from world.hec — look in parent of the given path.
/// Parses: `heki do\n  dir "information"\nend`
fn find_world_heki_dir(aggregates_path: &str) -> Option<String> {
    let parent = std::path::Path::new(aggregates_path).parent()?;
    let world_path = parent.join("world.hec");
    let content = fs::read_to_string(&world_path).ok()?;
    // Simple parse: find `dir "..."` inside `heki do...end`
    let mut in_heki = false;
    for line in content.lines() {
        let trimmed = line.trim();
        if trimmed.starts_with("heki") && trimmed.contains("do") { in_heki = true; }
        if in_heki && trimmed.starts_with("dir") {
            // Extract quoted string
            if let Some(start) = trimmed.find('"') {
                if let Some(end) = trimmed[start+1..].find('"') {
                    let dir = &trimmed[start+1..start+1+end];
                    return Some(parent.join(dir).to_string_lossy().into());
                }
            }
        }
        if in_heki && trimmed == "end" { in_heki = false; }
    }
    None
}

/// Dispatch a command through the hecksagon — merge all bluebooks, find the command, run it.
fn dispatch_hecksagon(agg_dir: &str, command: &str) {
    let data_dir = find_world_heki_dir(agg_dir)
        .unwrap_or_else(|| format!("{}/data", agg_dir.trim_end_matches('/')));
    let mut combined = hecks_life::ir::Domain {
        name: "Hecksagon".into(),
        category: None, vision: None,
        aggregates: vec![], policies: vec![],
        fixtures: vec![], vows: vec![],
    };
    let entries = fs::read_dir(agg_dir).unwrap_or_else(|e| {
        eprintln!("Cannot read directory {}: {}", agg_dir, e);
        std::process::exit(1);
    });
    for entry in entries.flatten() {
        let p = entry.path();
        if p.extension().map(|e| e == "bluebook").unwrap_or(false) {
            if let Ok(source) = fs::read_to_string(&p) {
                let domain = parser::parse(&source);
                combined.aggregates.extend(domain.aggregates);
                combined.policies.extend(domain.policies);
                combined.fixtures.extend(domain.fixtures);
            }
        }
    }
    let mut rt = Runtime::boot_with_data_dir(combined, Some(data_dir));
    match rt.dispatch(command, std::collections::HashMap::new()) {
        Ok(result) => {
            println!("{}", serde_json::json!({
                "ok": true,
                "aggregate": result.aggregate_type,
                "id": result.aggregate_id,
            }));
        }
        Err(e) => {
            eprintln!("dispatch error: {:?}", e);
            std::process::exit(1);
        }
    }
}

/// Resolve the project home directory for a named being.
/// 1. HECKS_HOME env var
/// 2. ~/.hecks_home file (single line: path to hecks_conception)
/// 3. Follow symlink from the binary to hecks_life/../hecks_conception
/// 4. Fall back to "."
fn resolve_home(_being: &str) -> String {
    // Check env var first
    if let Ok(home) = env::var("HECKS_HOME") {
        return home;
    }
    // Check ~/.hecks_home file
    if let Ok(home_dir) = env::var("HOME") {
        let home_file = format!("{}/.hecks_home", home_dir);
        eprintln!("  resolve_home: checking {}", home_file);
        match fs::read_to_string(&home_file) {
            Ok(contents) => {
                let path = contents.trim().to_string();
                eprintln!("  resolve_home: found path={}", path);
                if std::path::Path::new(&path).is_dir() {
                    return path;
                }
                eprintln!("  resolve_home: path is not a dir");
            }
            Err(e) => eprintln!("  resolve_home: read error: {}", e),
        }
    } else {
        eprintln!("  resolve_home: HOME not set");
    }
    // Try to resolve from the binary's real location
    // binary lives at hecks_life/target/release/hecks-life
    // project lives at hecks_conception (sibling of hecks_life)
    if let Ok(exe) = env::current_exe() {
        if let Ok(real) = exe.canonicalize() {
            if let Some(hecks2) = real.parent().and_then(|p| p.parent()).and_then(|p| p.parent()) {
                let conception = hecks2.join("hecks_conception");
                if conception.is_dir() {
                    return conception.to_string_lossy().into_owned();
                }
            }
        }
    }
    ".".into()
}

fn dirs() -> Option<String> {
    env::var("HOME").ok()
}

fn print_usage() {
    eprintln!("hecks-life — the Bluebook compiler and runtime\n");
    eprintln!("Usage: hecks-life <command> <bluebook-file> [options]\n");
    eprintln!("Commands:");
    eprintln!("  parse      Parse and print domain summary");
    eprintln!("  validate   Check domain for DDD consistency");
    eprintln!("  inspect    Full domain inspection with all details");
    eprintln!("  tree       Tree view of aggregates and commands");
    eprintln!("  list       Summary list of aggregates and commands");
    eprintln!("  run        Boot runtime with interactive REPL");
    eprintln!("  serve      Boot runtime as HTTP JSON API (file or directory)");
    eprintln!("  conceive   Generate a new domain from corpus archetypes");
    eprintln!("  develop    Develop features in an existing domain");
    eprintln!("  boot       Full boot: hydrate + nerves + prompt gen");
    eprintln!("  daemon     Run background daemons (pulse, daydream, sleep)");
    eprintln!("  hydrate    Load .heki stores and print vital signs");
    eprintln!("  heki       Read/write .heki binary stores\n");
    eprintln!("Heki subcommands:");
    eprintln!("  heki read   <file>           Dump store as JSON");
    eprintln!("  heki latest <file>           Show latest record");
    eprintln!("  heki append <file> k=v ...   Append new record");
    eprintln!("  heki upsert <file> k=v ...   Upsert singleton");
    eprintln!("  heki delete <file> <id>      Delete record by ID\n");
    eprintln!("Options:");
    eprintln!("  --seed <file>      Load seed commands at boot (run/serve)");
    eprintln!("  --corpus <dirs>    Corpus directories (conceive/develop)");
    eprintln!("  --add <feature>    Feature to add (develop)");
    eprintln!("  --from <path>      Source archetype bluebook (develop)");
}
