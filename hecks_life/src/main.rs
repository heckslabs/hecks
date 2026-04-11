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
//!   hecks-life conceive  "Name" "vision" --corpus dir1 dir2
//!   hecks-life develop   target.bluebook --add "feature"

use hecks_life::{parser, formatter, validator, server, repl, conceiver};
use hecks_life::runtime::Runtime;

use std::env;
use std::fs;

fn main() {
    let args: Vec<String> = env::args().collect();

    if args.len() < 2 {
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

    if path.is_empty() {
        eprintln!("Usage: hecks-life {} <bluebook-file>", command);
        std::process::exit(1);
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
        "counts" => {
            let cmds: usize = domain.aggregates.iter().map(|a| a.commands.len()).sum();
            println!("{}|{}|{}|{}|{}", domain.name, domain.aggregates.len(), cmds, domain.policies.len(), domain.fixtures.len());
        }
        "run" => {
            let mut rt = Runtime::boot(domain);
            load_seeds(&mut rt, seed_path);
            repl::run(rt);
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
                if errors.is_empty() { println!("VALID|{}", file_path); valid += 1; }
                else { println!("INVALID|{}|{}", file_path, errors.join("; ")); invalid += 1; }
            }
            "counts" => {
                let cmds: usize = domain.aggregates.iter().map(|a| a.commands.len()).sum();
                println!("{}|{}|{}|{}|{}|{}", file_path, domain.name, domain.aggregates.len(), cmds, domain.policies.len(), domain.fixtures.len());
                valid += 1;
            }
            _ => { eprintln!("Batch mode only supports: validate, counts"); std::process::exit(1); }
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
    eprintln!("  serve      Boot runtime as HTTP JSON API");
    eprintln!("  conceive   Generate a new domain from corpus archetypes");
    eprintln!("  develop    Develop features in an existing domain\n");
    eprintln!("Options:");
    eprintln!("  --seed <file>      Load seed commands at boot (run/serve)");
    eprintln!("  --corpus <dirs>    Corpus directories (conceive/develop)");
    eprintln!("  --add <feature>    Feature to add (develop)");
    eprintln!("  --from <path>      Source archetype bluebook (develop)");
}
