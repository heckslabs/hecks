//! Conceiver CLI commands — conceive and evolve entry points
//!
//! Handles argument parsing and orchestration for the `conceive`
//! and `evolve` subcommands of hecks-life.
//!
//! Usage:
//!   hecks-life conceive "Geology" "science of rocks" --corpus nursery catalog
//!   hecks-life evolve target.bluebook --add "audit logging"

use crate::conceiver;
use crate::parser;
use std::path::PathBuf;

/// Run the `conceive` command: generate a new domain from corpus archetypes.
pub fn run_conceive(args: &[String]) {
    let name = args.get(2).unwrap_or_else(|| {
        eprintln!("Usage: hecks-life conceive <name> \"<vision>\" [--corpus <dir>...]");
        std::process::exit(1);
    });
    let vision = args.get(3).unwrap_or_else(|| {
        eprintln!("Usage: hecks-life conceive <name> \"<vision>\" [--corpus <dir>...]");
        std::process::exit(1);
    });

    let corpus_dirs = parse_corpus_dirs(args);
    let corpus = conceiver::scan_corpus(&corpus_dirs);
    eprintln!("Scanned {} domains from {} dirs", corpus.len(), corpus_dirs.len());

    let seed = conceiver::vector::seed_from_description(vision);
    let matches = conceiver::find_nearest(&seed, corpus, 5);

    if matches.is_empty() {
        eprintln!("No corpus entries found. Check --corpus paths.");
        std::process::exit(1);
    }

    println!("Nearest archetypes:");
    for m in &matches {
        println!("  {}: {:.1}%", m.name, m.similarity * 100.0);
    }

    let best = &matches[0];
    let text = conceiver::generator::generate_bluebook(name, vision, &best.domain);
    let snake = name.to_lowercase().replace(' ', "_");
    let dir = format!("nursery/{}", snake);
    let path = format!("{}/{}.bluebook", dir, snake);

    std::fs::create_dir_all(&dir).ok();
    std::fs::write(&path, &text).unwrap_or_else(|e| {
        eprintln!("Cannot write {}: {}", path, e);
        std::process::exit(1);
    });

    println!("\nGenerated {}", path);
    println!("  Archetype: {} ({:.1}%)", best.name, best.similarity * 100.0);
    println!("  Aggregates: {}", best.domain.aggregates.len());
    let cmds: usize = best.domain.aggregates.iter().map(|a| a.commands.len()).sum();
    println!("  Commands: {}", cmds);
}

/// Run the `evolve` command: graft features onto an existing domain.
pub fn run_evolve(args: &[String]) {
    let bluebook_path = args.get(2).unwrap_or_else(|| {
        eprintln!("Usage: hecks-life evolve <path> --add <feature> [--from <path>]");
        std::process::exit(1);
    });
    let feature = args.iter().position(|a| a == "--add")
        .and_then(|i| args.get(i + 1))
        .unwrap_or_else(|| {
            eprintln!("--add <feature> is required");
            std::process::exit(1);
        });

    let source = std::fs::read_to_string(bluebook_path).unwrap_or_else(|e| {
        eprintln!("Cannot read {}: {}", bluebook_path, e);
        std::process::exit(1);
    });
    let target = parser::parse(&source);
    let from_path = args.iter().position(|a| a == "--from").and_then(|i| args.get(i + 1));

    let source_domain = if let Some(fp) = from_path {
        let s = std::fs::read_to_string(fp).unwrap_or_else(|e| {
            eprintln!("Cannot read {}: {}", fp, e);
            std::process::exit(1);
        });
        parser::parse(&s)
    } else {
        find_corpus_match(args, feature)
    };

    let old_vec = conceiver::vector::extract_vector(&target);
    let text = conceiver::evolve::evolve_bluebook(&target, &source_domain, feature);
    let evolved = parser::parse(&text);
    let new_vec = conceiver::vector::extract_vector(&evolved);

    std::fs::write(bluebook_path, &text).unwrap_or_else(|e| {
        eprintln!("Cannot write {}: {}", bluebook_path, e);
        std::process::exit(1);
    });

    println!("Evolved {}", bluebook_path);
    println!("  Feature: {}", feature);
    println!("  Old vector: {:?}", old_vec);
    println!("  New vector: {:?}", new_vec);
    println!("  Aggregates: {} -> {}", target.aggregates.len(), evolved.aggregates.len());
}

fn find_corpus_match(args: &[String], feature: &str) -> crate::ir::Domain {
    let corpus_dirs = parse_corpus_dirs(args);
    let corpus = conceiver::scan_corpus(&corpus_dirs);
    let keywords: Vec<String> = feature.to_lowercase().split_whitespace().map(String::from).collect();
    let best = corpus.into_iter().find(|e| {
        e.domain.aggregates.iter().any(|a| {
            let haystack = format!("{} {} {}",
                a.name.to_lowercase(),
                a.description.as_deref().unwrap_or("").to_lowercase(),
                a.commands.iter().map(|c| c.name.to_lowercase()).collect::<Vec<_>>().join(" ")
            );
            keywords.iter().any(|kw| haystack.contains(kw))
        })
    });
    match best {
        Some(e) => e.domain,
        None => {
            eprintln!("No corpus domain found matching feature \"{}\"", feature);
            std::process::exit(1);
        }
    }
}

/// Parse --corpus <dir1> <dir2> ... from args, with sensible defaults.
pub fn parse_corpus_dirs(args: &[String]) -> Vec<PathBuf> {
    if let Some(pos) = args.iter().position(|a| a == "--corpus") {
        let mut dirs = Vec::new();
        for a in &args[pos + 1..] {
            if a.starts_with("--") { break; }
            dirs.push(PathBuf::from(a));
        }
        if !dirs.is_empty() { return dirs; }
    }
    vec![PathBuf::from("nursery"), PathBuf::from("catalog")]
}
