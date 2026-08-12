//! `hecks-codegen` — Stage 7 of `/Users/christopheryoung/.claude/plans/sequential-petting-whale.md`:
//! a Rust port of (part of) `rust/project/*.rb`'s IR-to-Rust-source
//! codegen, standing beside the existing Ruby generator for differential
//! verification (`spec/codegen_parity_spec.rb`) — NOT wired into
//! `bin/project_rust` yet (that's Stage 8).
//!
//! See each module's own header for what it ports and why; `prelude.rs`
//! explains the scoped "prelude" comparison unit this stage's harness
//! actually verifies byte-exact, and the stage's own report names what's
//! deliberately not ported yet (commands/mutations/queries/read_models/
//! reactions/ports/registry/bridging.rb).
//!
//! Usage: `hecks-codegen prelude <ir.json> <source_label> <out_dir>` —
//! reads one chapter's `ir.json`, writes one `<aggregate_name_downcase>.rs`
//! prelude file per NOT-skipped aggregate into `out_dir`.
//!
//! `#![allow(dead_code)]` — a few `naming.rs` functions (`dispatch_fn_name`,
//! `reference_target`) are direct ports already sitting ready for the
//! still-unported commands/mutations slice (a follow-up stage), unused by
//! today's prelude-only call graph — same convention `rust/src/exemplar/
//! mod.rs` already uses for its own not-yet-exercised shapes.
#![allow(dead_code)]

mod attr;
mod bridging;
mod commands;
mod constraints;
mod domain_generator;
mod exemplar;
mod expr;
mod expr_emitter;
mod fielded;
mod hecksagain_naming;
mod json;
mod json_codec;
mod literal;
mod mutations;
mod naming;
mod ports;
mod prelude;
mod queries;
mod reactions;
mod read_models;
mod registry;
mod shared;
mod types;

use json::Json;
use std::process::ExitCode;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match run(&args) {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) => {
            eprintln!("hecks-codegen: {message}");
            ExitCode::from(1)
        }
    }
}

fn run(args: &[String]) -> Result<(), String> {
    match args.first().map(String::as_str) {
        Some("prelude") => run_prelude(&args[1..]),
        Some("domain") => run_domain(&args[1..]),
        _ => Err("usage: hecks-codegen <prelude|domain> <ir.json> <source_label> [mod_name] <out_dir>".to_string()),
    }
}

fn run_prelude(args: &[String]) -> Result<(), String> {
    let [ir_path, source_label, out_dir] = args else {
        return Err("usage: hecks-codegen prelude <ir.json> <source_label> <out_dir>".to_string());
    };

    let text = std::fs::read_to_string(ir_path).map_err(|e| format!("reading {ir_path}: {e}"))?;
    let ir = Json::parse(&text).map_err(|e| format!("parsing {ir_path}: {e}"))?;

    std::fs::create_dir_all(out_dir).map_err(|e| format!("creating {out_dir}: {e}"))?;

    let ex = exemplar::Exemplar::load();

    let aggregates = ir.get("aggregates").map(Json::each).unwrap_or(&[]);
    for aggregate in aggregates {
        let name = aggregate.get("name").and_then(Json::as_str).unwrap_or("");
        match prelude::aggregate_prelude(&ex, &ir, aggregate, source_label) {
            Some(text) => {
                let path = format!("{out_dir}/{}.rs", name.to_lowercase());
                std::fs::write(&path, text).map_err(|e| format!("writing {path}: {e}"))?;
                println!("wrote {path}");
            }
            None => {
                println!("skipping {name}: unsupported attribute type(s)");
            }
        }
    }

    Ok(())
}

/// `hecks-codegen domain <ir.json> <source_label> <mod_name> <out_dir>` —
/// the FULL per-chapter walk (`domain_generator::generate`, a port of
/// `DomainGenerator.call`): one `<aggregate>.rs` per generated aggregate,
/// `registry.rs`, and `mod.rs`. NOT written: `metadata.rs`/`ir.json`
/// (needs a JSON pretty-printer this crate doesn't have — see
/// `domain_generator.rs`'s own header) and `manifest.json` (bookkeeping
/// only) — named gaps, not silently dropped.
fn run_domain(args: &[String]) -> Result<(), String> {
    let [ir_path, source_label, mod_name, out_dir] = args else {
        return Err("usage: hecks-codegen domain <ir.json> <source_label> <mod_name> <out_dir>".to_string());
    };

    let text = std::fs::read_to_string(ir_path).map_err(|e| format!("reading {ir_path}: {e}"))?;
    let ir = Json::parse(&text).map_err(|e| format!("parsing {ir_path}: {e}"))?;

    std::fs::create_dir_all(out_dir).map_err(|e| format!("creating {out_dir}: {e}"))?;

    let ex = exemplar::Exemplar::load();
    let generated = domain_generator::generate(&ex, &ir, source_label, mod_name);

    for file in &generated.aggregate_files {
        let path = format!("{out_dir}/{}", file.name);
        std::fs::write(&path, &file.content).map_err(|e| format!("writing {path}: {e}"))?;
        println!("wrote {path}");
    }

    let registry_path = format!("{out_dir}/registry.rs");
    std::fs::write(&registry_path, &generated.registry_rs).map_err(|e| format!("writing {registry_path}: {e}"))?;
    println!("wrote {registry_path}");

    let mod_path = format!("{out_dir}/mod.rs");
    std::fs::write(&mod_path, &generated.mod_rs).map_err(|e| format!("writing {mod_path}: {e}"))?;
    println!("wrote {mod_path}");

    Ok(())
}
