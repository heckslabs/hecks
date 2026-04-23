//! `hecks-life conceive-behaviors` CLI subcommand.
//!
//! Mirrors `conceiver/commands.rs` in style. Reads a source bluebook,
//! optionally scans a corpus of existing `_behavioral_tests.bluebook`
//! suites for shape cues, generates a `<source>_behavioral_tests.bluebook`
//! next to the source.
//!
//! Usage:
//!   hecks-life conceive-behaviors path/to/source.bluebook [--corpus dir1 dir2]
//!   hecks-life conceive-behaviors path/to/source.bluebook --force   # overwrite

use crate::behaviors_conceiver::{self, BehaviorsConceiver, MatchSuiteExt};
use crate::conceiver::commands::parse_corpus_dirs;
use crate::conceiver_common::{self, Conceiver};
use crate::parser;
use std::path::PathBuf;

pub fn run_conceive_behaviors(args: &[String]) {
    let source_path = args.get(2).unwrap_or_else(|| {
        eprintln!("Usage: hecks-life conceive-behaviors <source.bluebook> [--corpus <dir>...]");
        std::process::exit(1);
    });

    let force = args.iter().any(|a| a == "--force");

    let source = std::fs::read_to_string(source_path).unwrap_or_else(|e| {
        eprintln!("Cannot read {}: {}", source_path, e);
        std::process::exit(1);
    });
    let domain = parser::parse(&source);
    if domain.aggregates.is_empty() {
        eprintln!("Source bluebook has no aggregates — nothing to test");
        std::process::exit(1);
    }

    // Pick an archetype suite from corpus (if any). With a one-suite
    // corpus the only archetype IS the only entry; with more, the
    // nearest by source-domain shape wins.
    let corpus_dirs = parse_corpus_dirs(args);
    let corpus = conceiver_common::scan_corpus::<BehaviorsConceiver>(&corpus_dirs);
    eprintln!("Scanned {} test suite(s) from {} dirs", corpus.len(), corpus_dirs.len());

    let archetype = if !corpus.is_empty() {
        let seed = BehaviorsConceiver::seed_vector(&domain);
        let matches = conceiver_common::find_nearest(&seed, corpus, 5);
        if !matches.is_empty() {
            println!("Nearest archetype suites:");
            for m in &matches { println!("  {}: {:.1}%", m.name, m.similarity * 100.0); }
        }
        matches.into_iter().next().map(|m| m.suite_owned())
    } else {
        None
    };

    let text = behaviors_conceiver::generator::generate_behaviors(&domain, archetype.as_ref());

    // i4 gap 4: surface dangling gate-flag warnings on stderr too. The
    // generated file carries them as `# ⚠` header comments for durability,
    // but most invocations only scan stderr/stdout — print there so the
    // problem is visible the moment the modeler regenerates.
    // [antibody-exempt: conceiver fix per i4 gap 4; retires when conceivers port to a bluebook-dispatched form]
    let gate_warnings = behaviors_conceiver::generator::detect_dangling_gate_flags(&domain);
    for (agg, attr) in &gate_warnings {
        eprintln!("⚠ gate-flag :{} on {} has no flipper — add a command that `then_set :{}, to: true`, or mark it read-only", attr, agg, attr);
    }

    let target = target_path(source_path);
    if std::path::Path::new(&target).exists() && !force {
        eprintln!("\n{} already exists.", target);
        eprintln!("To overwrite, re-run with --force.");
        eprintln!("To preview the diff:");
        eprintln!("  diff -u {} <(hecks-life conceive-behaviors {} --print)", target, source_path);
        std::process::exit(1);
    }

    std::fs::write(&target, &text).unwrap_or_else(|e| {
        eprintln!("Cannot write {}: {}", target, e);
        std::process::exit(1);
    });
    println!("\nGenerated {}", target);
    let cmd_count: usize = domain.aggregates.iter().map(|a| a.commands.len()).sum();
    let q_count:   usize = domain.aggregates.iter().map(|a| a.queries.len()).sum();
    println!("  Source: {} ({} aggregates, {} commands, {} queries)",
             domain.name, domain.aggregates.len(), cmd_count, q_count);
}

/// `path/to/foo.bluebook` → `path/to/foo.behaviors`.
fn target_path(source: &str) -> String {
    let p = PathBuf::from(source);
    let parent = p.parent().map(|p| p.to_path_buf()).unwrap_or_else(|| PathBuf::from("."));
    let stem = p.file_stem().and_then(|s| s.to_str()).unwrap_or("source");
    parent.join(format!("{}.behaviors", stem))
        .to_string_lossy().into_owned()
}
