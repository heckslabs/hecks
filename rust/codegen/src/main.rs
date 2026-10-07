//! `hecks-codegen` — the IR-to-Rust-source generator, the only one (ADR 0086).
//! Usage: `hecks-codegen <prelude|domain|full> ...`, one subcommand per function below.
// Some ported `naming.rs` helpers are not called yet.
#![allow(dead_code)]

mod attr;
mod bridging;
mod commands;
mod constraints;
mod dependency_planning;
mod domain_generator;
mod exemplar;
mod expr_emitter;
mod fielded;
mod hecks_naming;
mod json;
mod json_codec;
mod literal;
mod manifest;
mod mutations;
mod naming;
mod optional_pass;
mod ports;
mod prelude;
mod queries;
mod reactions;
mod read_models;
mod reference_specs;
mod registry;
mod reserved_names;
mod shared;
mod sidecars;
mod skip_reason;
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
                let path = format!("{out_dir}/{}.rs", naming::aggregate_module(name));
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

/// `hecks-codegen domain <ir.json> <source_label> <mod_name> <out_dir>` — writes one chapter's
/// `<aggregate>.rs`, `registry.rs`, `mod.rs`, `manifest.json` and its `ir.json`/`metadata.rs`
/// sidecars into `out_dir`.
fn run_domain(args: &[String]) -> Result<(), String> {
    let [ir_path, source_label, mod_name, out_dir] = args else {
        return Err("usage: hecks-codegen domain <ir.json> <source_label> <mod_name> <out_dir>".to_string());
    };

    let ir = read_ir(ir_path)?;

    let ex = exemplar::Exemplar::load();
    write_domain(&ex, &ir, source_label, mod_name, out_dir)?;
    Ok(())
}

/// Reads one chapter's IR and prepares it for generation: marks the fields an `append` binds to an
/// optional argument. What it generates from and what it writes to `ir.json` are this same IR.
fn read_ir(path: &str) -> Result<Json, String> {
    let text = std::fs::read_to_string(path).map_err(|e| format!("reading {path}: {e}"))?;
    let mut ir = Json::parse(&text).map_err(|e| format!("parsing {path}: {e}"))?;
    optional_pass::run(&mut ir);
    Ok(ir)
}

/// Writes one chapter's files into `out_dir` and returns the `GeneratedDomain`, so `run_full`
/// can union the registry, query and read-model definitions across chapters.
fn write_domain(
    ex: &exemplar::Exemplar,
    ir: &Json,
    source_label: &str,
    mod_name: &str,
    out_dir: &str,
) -> Result<domain_generator::GeneratedDomain, String> {
    // Refuse before writing anything, so a name collision is reported before any file exists.
    let aggregate_names: Vec<&str> = ir
        .get("aggregates")
        .map(Json::each)
        .unwrap_or(&[])
        .iter()
        .map(|a| a.get("name").and_then(Json::as_str).unwrap_or(""))
        .collect();
    if let Some(refusal) = naming::reserved_name_refusal(source_label, mod_name, &aggregate_names) {
        return Err(refusal);
    }
    if let Some(refusal) = naming::unsafe_name_refusal(source_label, ir) {
        return Err(refusal);
    }

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

    let manifest_path = format!("{out_dir}/manifest.json");
    std::fs::write(&manifest_path, &generated.manifest_json).map_err(|e| format!("writing {manifest_path}: {e}"))?;
    println!("wrote {manifest_path}");

    let (ir_json_path, metadata_path) = sidecars::write(std::path::Path::new(out_dir), ir, source_label)?;
    println!("wrote {}", ir_json_path.display());
    println!("wrote {}", metadata_path.display());

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

/// `hecks-codegen full <out_root> <target_mod_name> <target_source_label> <target_ir.json>
/// [<chapter_mod_name> <chapter_source_label> <chapter_ir.json>]...`
///
/// Writes the target chapter's directory, each attached chapter's own directory, and the
/// target's `merged.rs`: one `Store`/`dispatch_by_name` table spanning every chapter given.
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

    let target_ir = read_ir(target_ir_path)?;
    let target_domain_name = target_ir.get("name").and_then(Json::as_str).unwrap_or("").to_string();

    let target_out_dir = format!("{out_root}/{target_mod_name}");
    let target_gen = write_domain(&ex, &target_ir, target_source_label, target_mod_name, &target_out_dir)?;

    // Target first, then each attached chapter in command-line order.
    let mut reference_key_pairs: Vec<(String, Vec<String>)> =
        vec![(target_domain_name.clone(), target_gen.registry_aggregates.iter().map(|a| a.name.clone()).collect())];

    let mut merged_aggregates = target_gen.registry_aggregates;
    let mut merged_queries = target_gen.query_defs;
    let mut merged_read_models = target_gen.read_model_defs;
    let mut merged_process_managers: Vec<Json> = target_ir.get("process_managers").map(Json::each).unwrap_or(&[]).to_vec();

    // Policies and process managers merge across chapters; `chapter_irs` keeps each parsed
    // chapter alive so `policy_sources` can borrow from it.
    let mut chapter_irs: Vec<Json> = Vec::new();
    let mut chapter_domain_names: Vec<String> = Vec::new();

    let mut i = 4;
    while i < args.len() {
        let chapter_mod_name = &args[i];
        let chapter_source_label = &args[i + 1];
        let chapter_ir_path = &args[i + 2];
        i += 3;

        let chapter_ir = read_ir(chapter_ir_path)?;
        let chapter_domain_name = chapter_ir.get("name").and_then(Json::as_str).unwrap_or("").to_string();

        let chapter_out_dir = format!("{out_root}/{chapter_mod_name}");
        let chapter_gen = write_domain(&ex, &chapter_ir, chapter_source_label, chapter_mod_name, &chapter_out_dir)?;

        reference_key_pairs.push((chapter_domain_name.clone(), chapter_gen.registry_aggregates.iter().map(|a| a.name.clone()).collect()));
        merged_aggregates.extend(chapter_gen.registry_aggregates);
        merged_queries.extend(chapter_gen.query_defs);
        merged_read_models.extend(chapter_gen.read_model_defs);
        merged_process_managers.extend(chapter_ir.get("process_managers").map(Json::each).unwrap_or(&[]).to_vec());

        chapter_domain_names.push(chapter_domain_name);
        chapter_irs.push(chapter_ir);
    }

    // One entry per chapter, so its policies qualify against its own domain and aggregates.
    let policies: Vec<Json> = target_ir.get("policies").map(Json::each).unwrap_or(&[]).to_vec();
    let policy_aggregates: Vec<Json> = target_ir.get("aggregates").map(Json::each).unwrap_or(&[]).to_vec();

    let mut policy_sources: Vec<reactions::PolicySource> =
        vec![reactions::PolicySource { domain_name: &target_domain_name, policies: &policies, aggregates: &policy_aggregates }];
    for (name, ir) in chapter_domain_names.iter().zip(chapter_irs.iter()) {
        policy_sources.push(reactions::PolicySource {
            domain_name: name,
            policies: ir.get("policies").map(Json::each).unwrap_or(&[]),
            aggregates: ir.get("aggregates").map(Json::each).unwrap_or(&[]),
        });
    }

    let mut merged_rs = String::new();
    puts_str(&mut merged_rs, &crate::registry::emit_registry(&ex, &merged_aggregates));
    puts_blank(&mut merged_rs);
    puts_str(&mut merged_rs, &crate::registry::emit_reference_lookup(&merged_aggregates));
    puts_blank(&mut merged_rs);
    puts_str(&mut merged_rs, &reactions::emit_merged_policy_table(&ex, &policy_sources));
    puts_blank(&mut merged_rs);
    puts_str(&mut merged_rs, &reactions::emit_merged_cross_domain_policy_table(&ex, &policy_sources));
    puts_blank(&mut merged_rs);
    puts_str(&mut merged_rs, &reactions::emit_process_manager_table(&ex, &merged_process_managers));
    puts_blank(&mut merged_rs);
    puts_str(&mut merged_rs, &reactions::emit_reference_key_table(&ex, &reference_key_pairs));
    puts_blank(&mut merged_rs);
    puts_str(&mut merged_rs, &reactions::emit_creates_table(&ex, &merged_aggregates));
    puts_blank(&mut merged_rs);
    puts_str(&mut merged_rs, &reactions::emit_identity_head_table(&ex, &merged_aggregates));
    puts_blank(&mut merged_rs);
    // Section order is part of the output: `hecks regenerate_corpus --check` diffs this file byte for byte.
    puts_str(&mut merged_rs, &reactions::emit_entity_identity_head_table(&ex, &merged_aggregates));
    puts_blank(&mut merged_rs);
    puts_str(&mut merged_rs, &reactions::emit_command_attributes_table(&ex, &merged_aggregates));
    puts_blank(&mut merged_rs);
    puts_str(&mut merged_rs, &queries::emit_query_table(&ex, &merged_queries));
    puts_blank(&mut merged_rs);
    puts_str(&mut merged_rs, &queries::emit_query_arg_check_table(&merged_queries));
    puts_blank(&mut merged_rs);
    for rmd in &merged_read_models {
        if let Some(body) = &rmd.group_by_fn_body {
            puts_str(&mut merged_rs, body);
            puts_blank(&mut merged_rs);
        }
    }
    puts_str(&mut merged_rs, &read_models::emit_read_model_table(&ex, &merged_read_models));

    let merged_path = format!("{target_out_dir}/merged.rs");
    std::fs::write(&merged_path, &merged_rs).map_err(|e| format!("writing {merged_path}: {e}"))?;
    println!("wrote {merged_path}");

    // `write_domain` already wrote `mod.rs`; only the target directory gets a `merged` module.
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
