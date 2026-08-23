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
mod reference_specs;
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
        Some("full") => run_full(&args[1..]),
        _ => Err("usage: hecks-codegen <prelude|domain|full> ...".to_string()),
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
/// `registry.rs`, and `mod.rs`. NOT written here: `metadata.rs`/`ir.json`
/// (this subcommand only ever sees ALREADY-PARSED `ir.json`, on disk —
/// `bin/project_rust`'s own opt-in orchestration writes those two
/// straight from the exact bytes `hecks-parse chapter` already emitted
/// plus a plain `String#inspect` call, never re-derived here — see that
/// script's own header on why re-serializing JSON in this crate was
/// judged unnecessary, not merely deferred) and `manifest.json`
/// (bookkeeping only, see `run_full`'s own header) — named gaps, not
/// silently dropped.
fn run_domain(args: &[String]) -> Result<(), String> {
    let [ir_path, source_label, mod_name, out_dir] = args else {
        return Err("usage: hecks-codegen domain <ir.json> <source_label> <mod_name> <out_dir>".to_string());
    };

    let text = std::fs::read_to_string(ir_path).map_err(|e| format!("reading {ir_path}: {e}"))?;
    let ir = Json::parse(&text).map_err(|e| format!("parsing {ir_path}: {e}"))?;

    let ex = exemplar::Exemplar::load();
    write_domain(&ex, &ir, source_label, mod_name, out_dir)?;
    Ok(())
}

/// Shared by `run_domain` and `run_full`: writes one chapter's own
/// `<aggregate>.rs`/`registry.rs`/`mod.rs` into `out_dir`, returning the
/// `GeneratedDomain` so a multi-chapter caller (`run_full`) can union
/// its `registry_aggregates`/`query_defs`/`read_model_defs` with every
/// OTHER chapter's own, the same way `bin/project_rust`'s Ruby
/// orchestration already unions `RustProjection::DomainGenerator.call`'s
/// own return Hash across chapters for `merged.rs`.
fn write_domain(
    ex: &exemplar::Exemplar,
    ir: &Json,
    source_label: &str,
    mod_name: &str,
    out_dir: &str,
) -> Result<domain_generator::GeneratedDomain, String> {
    std::fs::create_dir_all(out_dir).map_err(|e| format!("creating {out_dir}: {e}"))?;

    let generated = domain_generator::generate(ex, ir, source_label, mod_name);

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

    Ok(generated)
}

fn puts_str(out: &mut String, s: &str) {
    out.push_str(s);
    if !s.ends_with('\n') {
        out.push('\n');
    }
}

fn puts_blank(out: &mut String) {
    out.push('\n');
}

/// `hecks-codegen full <out_root> <target_mod_name> <target_source_label>
/// <target_ir.json> [<chapter_mod_name> <chapter_source_label>
/// <chapter_ir.json>]...` — STAGE 8: the Rust-side equivalent of
/// EVERYTHING `bin/project_rust`'s own Ruby orchestration does beyond a
/// single `RustProjection::DomainGenerator.call` (that file's own
/// header, quoted in the stage 8 plan): the target chapter's own
/// directory, EVERY attached framework chapter's own directory (each
/// standalone, via the SAME `write_domain` a lone `domain` subcommand
/// call would produce), and finally the target's own `merged.rs` —
/// ONE UNIONED `Store`/`dispatch_by_name` table spanning the target
/// chapter AND every chapter given after it, exactly the shape
/// `bin/project_rust`'s own `merged_aggregates = target_aggregates +
/// framework_aggregates` (+ `merged_queries`/`merged_read_models`)
/// builds today. Calling this with ZERO trailing chapter triples (just
/// the target) reproduces `bin/project_rust`'s own META special case
/// (`meta_merged_path`) for free — meta attaches no framework chapters
/// of its own, so "union of one" is exactly its own single-chapter
/// registry, restated under the `merged.rs` filename every other domain
/// already gets, same as that script's own comment says.
///
/// NOT written here: `metadata.rs`/`ir.json` per directory (the
/// orchestrator's own job — see `run_domain`'s header) and
/// `manifest.json` (the coverage manifest `bin/rust_coverage` reads —
/// `domain_generator.rb`'s own per-construct `manifest_entry` tracking
/// was judged out of scope for this stage: it is bookkeeping ABOUT the
/// generator's decisions, with "no bearing on whether the generated
/// `.rs` source is correct" per that file's own header, and porting its
/// ~15 call sites' worth of skip-reason tracking into this crate would
/// duplicate logic `commands.rs`/`queries.rs`/`read_models.rs`/etc.
/// already compute for the REAL decision, not add any new correctness
/// coverage. Left an explicit, named Ruby-only gap for now, not a
/// silent drop — `bin/project_rust`'s own opt-in branch says so again
/// at the point it skips writing the file).
fn run_full(args: &[String]) -> Result<(), String> {
    if args.len() < 4 || (args.len() - 4) % 3 != 0 {
        return Err(
            "usage: hecks-codegen full <out_root> <target_mod_name> <target_source_label> <target_ir.json> [<chapter_mod_name> <chapter_source_label> <chapter_ir.json>]..."
                .to_string(),
        );
    }

    let out_root = &args[0];
    let target_mod_name = &args[1];
    let target_source_label = &args[2];
    let target_ir_path = &args[3];

    let ex = exemplar::Exemplar::load();

    let target_text = std::fs::read_to_string(target_ir_path).map_err(|e| format!("reading {target_ir_path}: {e}"))?;
    let target_ir = Json::parse(&target_text).map_err(|e| format!("parsing {target_ir_path}: {e}"))?;
    let target_domain_name = target_ir.get("name").and_then(Json::as_str).unwrap_or("").to_string();

    let target_out_dir = format!("{out_root}/{target_mod_name}");
    let target_gen = write_domain(&ex, &target_ir, target_source_label, target_mod_name, &target_out_dir)?;

    // `chapter_mod_names.map { |mod_name, chapter_name| [chapter_name,
    // ...] }` in Ruby — target FIRST (Ruby's seed Hash entry), each
    // attached chapter appended in the order it's given on the command
    // line (which `bin/project_rust`'s orchestrator itself derives from
    // `hecks-parse resolve`'s own `uses_framework` order — file order,
    // same as `target_registry.bluebooks.keys` would insert them).
    let mut reference_key_pairs: Vec<(String, Vec<String>)> =
        vec![(target_domain_name.clone(), target_gen.registry_aggregates.iter().map(|a| a.name.clone()).collect())];

    let mut merged_aggregates = target_gen.registry_aggregates;
    let mut merged_queries = target_gen.query_defs;
    let mut merged_read_models = target_gen.read_model_defs;

    let mut i = 4;
    while i < args.len() {
        let chapter_mod_name = &args[i];
        let chapter_source_label = &args[i + 1];
        let chapter_ir_path = &args[i + 2];
        i += 3;

        let text = std::fs::read_to_string(chapter_ir_path).map_err(|e| format!("reading {chapter_ir_path}: {e}"))?;
        let chapter_ir = Json::parse(&text).map_err(|e| format!("parsing {chapter_ir_path}: {e}"))?;
        let chapter_domain_name = chapter_ir.get("name").and_then(Json::as_str).unwrap_or("").to_string();

        let chapter_out_dir = format!("{out_root}/{chapter_mod_name}");
        let chapter_gen = write_domain(&ex, &chapter_ir, chapter_source_label, chapter_mod_name, &chapter_out_dir)?;

        reference_key_pairs.push((chapter_domain_name, chapter_gen.registry_aggregates.iter().map(|a| a.name.clone()).collect()));
        merged_aggregates.extend(chapter_gen.registry_aggregates);
        merged_queries.extend(chapter_gen.query_defs);
        merged_read_models.extend(chapter_gen.read_model_defs);
    }

    // POLICIES/PROCESS MANAGERS COME FROM THE TARGET ALONE, never
    // unioned across chapters — matches `bin/project_rust`'s own
    // `emit_policy_table(target_domain_name, target_ir[:policies])`
    // exactly (that script's own comment: Governance/Identity declare
    // none today, and real cross-chapter policy routing is a separate,
    // still-open gap, not attempted here either).
    let policies: Vec<Json> = target_ir.get("policies").map(Json::each).unwrap_or(&[]).to_vec();
    let policy_aggregates: Vec<Json> = target_ir.get("aggregates").map(Json::each).unwrap_or(&[]).to_vec();
    let process_managers: Vec<Json> = target_ir.get("process_managers").map(Json::each).unwrap_or(&[]).to_vec();

    let mut merged_rs = String::new();
    puts_str(&mut merged_rs, &crate::registry::emit_registry(&ex, &merged_aggregates));
    puts_blank(&mut merged_rs);
    puts_str(&mut merged_rs, &crate::registry::emit_reference_lookup(&merged_aggregates));
    puts_blank(&mut merged_rs);
    puts_str(&mut merged_rs, &reactions::emit_policy_table(&ex, &target_domain_name, &policies, &policy_aggregates));
    puts_blank(&mut merged_rs);
    puts_str(&mut merged_rs, &reactions::emit_cross_domain_policy_table(&ex, &target_domain_name, &policies));
    puts_blank(&mut merged_rs);
    puts_str(&mut merged_rs, &reactions::emit_process_manager_table(&ex, &process_managers));
    puts_blank(&mut merged_rs);
    puts_str(&mut merged_rs, &reactions::emit_reference_key_table(&ex, &reference_key_pairs));
    puts_blank(&mut merged_rs);
    puts_str(&mut merged_rs, &reactions::emit_creates_table(&ex, &merged_aggregates));
    puts_blank(&mut merged_rs);
    puts_str(&mut merged_rs, &reactions::emit_identity_head_table(&ex, &merged_aggregates));
    puts_blank(&mut merged_rs);
    puts_str(&mut merged_rs, &queries::emit_query_table(&ex, &merged_queries));
    puts_blank(&mut merged_rs);
    puts_str(&mut merged_rs, &read_models::emit_read_model_table(&ex, &merged_read_models));

    let merged_path = format!("{target_out_dir}/merged.rs");
    std::fs::write(&merged_path, &merged_rs).map_err(|e| format!("writing {merged_path}: {e}"))?;
    println!("wrote {merged_path}");

    // APPENDED, not written fresh — `write_domain` already wrote this
    // directory's own `mod.rs` (metadata/registry/one line per
    // aggregate module) above; `merged` is a FIFTH module only the
    // TARGET directory ever gets (this function's own header —
    // attached framework chapters stay standalone, no `merged.rs` of
    // their own), matching `bin/project_rust`'s own
    // `File.open(mod_path, "a") { f.puts "pub mod merged;" }`.
    let mod_path = format!("{target_out_dir}/mod.rs");
    let mut mod_rs = std::fs::read_to_string(&mod_path).map_err(|e| format!("reading {mod_path}: {e}"))?;
    if !mod_rs.ends_with('\n') {
        mod_rs.push('\n');
    }
    mod_rs.push_str("pub mod merged;\n");
    std::fs::write(&mod_path, &mod_rs).map_err(|e| format!("writing {mod_path}: {e}"))?;
    println!("appended 'pub mod merged;' to {mod_path}");

    Ok(())
}
