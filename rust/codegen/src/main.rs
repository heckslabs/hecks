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
mod constraints;
mod exemplar;
mod expr;
mod expr_emitter;
mod fielded;
mod hecksagain_naming;
mod json;
mod json_codec;
mod naming;
mod prelude;
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
        _ => Err("usage: hecks-codegen prelude <ir.json> <source_label> <out_dir>".to_string()),
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
