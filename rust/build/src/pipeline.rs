//! `RustProjectPipeline.call` (`rust/project_rust_pipeline.rb`), ported
//! to Rust — the crate's own orchestration core. Reads a domain's
//! `.bluebook`/`.hecksagon` header text (plain scanning, never a
//! `Kernel.load`-equivalent — there is no interpreter here to load
//! anything INTO), shells out to `hecks-parse`/`hecks-codegen` exactly
//! the way the Ruby original shells out to the same two binaries, runs
//! this crate's own `optional_pass::run` (the Rust port of
//! `mark_append_optional_fields!`) on each chapter's freshly-parsed
//! `ir.json` before handing it to codegen, runs `lineage_pass::run` on
//! the TARGET chapter's own `ir.json` only (matching the default Ruby
//! path's own `target_ir[:lineage] = ...` — never set on a framework
//! chapter or on `meta`), writes the same sidecars, and syncs
//! `rust/Cargo.toml`. See each helper module's own header for the piece
//! it owns; this file is the sequencing, matching
//! `RustProjectPipeline.call`'s own body step for step.
//!
//! ONE NAMED, DELIBERATE GAP remains — `manifest.json` (coverage
//! bookkeeping only, no bearing on whether the generated `.rs` source is
//! correct). The `lineage` key gap is CLOSED (`lineage_pass`'s own
//! header has the full reasoning) — see
//! `rust/project_rust_pipeline.rb`'s own header for that fix's own
//! Ruby-side account, which this crate mirrors rather than re-deriving.

use std::path::{Path, PathBuf};

use crate::build_artifact;
use crate::cargo_sync;
use crate::json::Json;
use crate::lineage_pass;
use crate::optional_pass;
use crate::resolve;
use crate::sidecars;
use crate::subprocess;
use crate::tmp::TempDir;

pub struct Options {
    pub build_native: bool,
    pub build_wasm: bool,
}

struct Chapter {
    mod_name: String,
    source_label: String,
    ir_text: String,
}

const META_SOURCE_LABEL: &str = "the self-hosted language (lib/hecksagain/language/bluebook)";

pub fn run(root: &Path, domain: &str, opts: &Options) -> Result<(), String> {
    let parser_dir = root.join("rust/parser");
    let codegen_dir = root.join("rust/codegen");
    ensure_binaries_built(&parser_dir, &codegen_dir)?;
    let parser_bin = parser_dir.join("target/debug/hecks-parse");
    let codegen_bin = codegen_dir.join("target/debug/hecks-codegen");

    let domain_path = PathBuf::from(domain);
    let target_mod_name = domain_path
        .file_name()
        .and_then(|s| s.to_str())
        .ok_or_else(|| format!("could not determine a module name from domain path {domain:?}"))?
        .to_string();

    let bluebook_directory = domain_path.join("bluebook");
    let bluebook_paths = resolve::bluebook_files(&bluebook_directory)?;
    let first_bluebook = bluebook_paths.first().ok_or_else(|| format!("{} has no .bluebook files", domain_path.display()))?;
    let hecksagon_candidate = bluebook_directory.join(format!("{target_mod_name}.hecksagon"));
    let hecksagon_path = hecksagon_candidate.is_file().then_some(hecksagon_candidate);

    let target_chapter_name = resolve::header_chapter_name(first_bluebook)?;
    let mut target_files = Vec::new();
    for path in bluebook_paths {
        if resolve::header_chapter_name(&path)? == target_chapter_name {
            target_files.push(path);
        }
    }

    let uses_framework_names = match &hecksagon_path {
        Some(p) => resolve::resolve_uses_framework(&parser_bin, &target_chapter_name, p)?,
        None => Vec::new(),
    };

    if let Some(p) = &hecksagon_path {
        target_files.push(p.clone());
    }
    let target_ir_text = parse_chapter_with_optionals(&parser_bin, &target_chapter_name, &target_files)?;
    // ONLY the target — see this file's own header on why a framework
    // chapter or `meta` never gets a `lineage` key either. A second,
    // independent parse/mutate/re-emit pass over the already-derived
    // text, mirroring `derive_lineage(target_ir_text, hecksagon_path)`
    // (Ruby) taking a STRING and re-`JSON.parse`ing it rather than
    // chaining a live object through both passes — the same structure,
    // not an accident of this port.
    let mut target_ir = Json::parse(&target_ir_text).map_err(|e| format!("re-parsing target ir.json for lineage: {e}"))?;
    lineage_pass::run(&mut target_ir, hecksagon_path.as_deref(), root)?;
    let target_ir_text = crate::json::write(&target_ir);

    // EVERY OTHER CHAPTER `uses_framework` NAMES — resolved through the
    // SAME `Hecksagain::Framework.members`-equivalent directory listing
    // (`resolve::framework_members`) the Ruby pipeline itself calls,
    // never hand-derived.
    let framework_members = resolve::framework_members(root)?;
    let mut chapters: Vec<Chapter> = Vec::new();
    for fw_name in &uses_framework_names {
        let fw_path = framework_members
            .iter()
            .find(|(name, _)| name == fw_name)
            .map(|(_, path)| path.clone())
            .ok_or_else(|| {
                let known: Vec<&str> = framework_members.iter().map(|(n, _)| n.as_str()).collect();
                format!("hecks-build: uses_framework {fw_name:?} names no known framework member — known: {}", known.join(", "))
            })?;
        let fw_chapter_name = resolve::header_chapter_name(&fw_path)?;
        if &fw_chapter_name != fw_name {
            return Err(format!(
                "hecks-build: {} declares chapter {fw_chapter_name:?}, but uses_framework named {fw_name:?}",
                fw_path.display()
            ));
        }
        let fw_ir_text = parse_chapter_with_optionals(&parser_bin, &fw_chapter_name, std::slice::from_ref(&fw_path))?;
        chapters.push(Chapter {
            mod_name: fw_name.to_lowercase(),
            source_label: format!("{domain} (uses_framework {fw_name:?})"),
            ir_text: fw_ir_text,
        });
    }

    // THE SELF-HOSTED LANGUAGE, COMPILED IN TOO — one discovered concept
    // folder, the same "Bluebook" chapter name.
    let grammar_files = resolve::grammar_files(root)?;
    let meta_ir_text = parse_chapter_with_optionals(&parser_bin, "Bluebook", &grammar_files)?;

    let out_root = root.join("rust/src/generated");
    std::fs::create_dir_all(&out_root).map_err(|e| format!("creating {}: {e}", out_root.display()))?;

    // SCOPED clearing — identical reasoning to both Ruby pipelines'
    // own: multiple domains coexist on disk, so only THIS run's own
    // directories are wiped first.
    remove_dir_if_exists(&out_root.join("meta"))?;
    remove_dir_if_exists(&out_root.join("active"))?;
    remove_dir_if_exists(&out_root.join(&target_mod_name))?;
    for c in &chapters {
        remove_dir_if_exists(&out_root.join(&c.mod_name))?;
    }

    let tmp = TempDir::new("hecks-build-codegen")?;

    let meta_ir_path = tmp.path().join("meta_ir.json");
    std::fs::write(&meta_ir_path, &meta_ir_text).map_err(|e| format!("writing {}: {e}", meta_ir_path.display()))?;
    run_codegen_full(&codegen_bin, &[out_root.to_string_lossy().to_string(), "meta".to_string(), META_SOURCE_LABEL.to_string(), meta_ir_path.to_string_lossy().to_string()])?;

    let target_ir_path = tmp.path().join("target_ir.json");
    std::fs::write(&target_ir_path, &target_ir_text).map_err(|e| format!("writing {}: {e}", target_ir_path.display()))?;

    let mut codegen_args = vec![
        out_root.to_string_lossy().to_string(),
        target_mod_name.clone(),
        domain.to_string(),
        target_ir_path.to_string_lossy().to_string(),
    ];
    let mut chapter_ir_paths = Vec::new();
    for (idx, c) in chapters.iter().enumerate() {
        let ir_path = tmp.path().join(format!("chapter_{idx}_ir.json"));
        std::fs::write(&ir_path, &c.ir_text).map_err(|e| format!("writing {}: {e}", ir_path.display()))?;
        codegen_args.push(c.mod_name.clone());
        codegen_args.push(c.source_label.clone());
        codegen_args.push(ir_path.to_string_lossy().to_string());
        chapter_ir_paths.push(ir_path);
    }
    run_codegen_full(&codegen_bin, &codegen_args)?;

    sidecars::write(&out_root.join("meta"), &meta_ir_text, META_SOURCE_LABEL)?;
    sidecars::write(&out_root.join(&target_mod_name), &target_ir_text, domain)?;
    for c in &chapters {
        sidecars::write(&out_root.join(&c.mod_name), &c.ir_text, &c.source_label)?;
    }

    eprintln!(
        "hecks-build: manifest.json NOT written for any directory above — coverage bookkeeping only, \
         no bearing on whether the generated .rs source is correct (rust/codegen/src/main.rs's own \
         `run_full` header has the full reasoning)."
    );

    let cargo_toml_path = root.join("rust/Cargo.toml");
    cargo_sync::run(&out_root, &cargo_toml_path, &target_mod_name)?;

    let rust_dir = root.join("rust");
    if opts.build_native {
        build_artifact::build_native(&rust_dir)?;
    }
    if opts.build_wasm {
        build_artifact::build_wasm(root, &rust_dir, &target_mod_name)?;
    }

    Ok(())
}

/// `hecks-parse chapter --chapter <Name> <files...>`, followed
/// immediately by this crate's own `optional_pass::run` and re-emission
/// — matching `derive_append_optionals(run_capture!(PARSER_BIN,
/// "chapter", ...))` (Ruby) exactly: parse once, mutate once,
/// re-serialize once, never touched again.
fn parse_chapter_with_optionals(parser_bin: &Path, chapter_name: &str, files: &[PathBuf]) -> Result<String, String> {
    let parser_bin_str = parser_bin.to_string_lossy().to_string();
    let mut args: Vec<String> = vec!["chapter".to_string(), "--chapter".to_string(), chapter_name.to_string()];
    args.extend(files.iter().map(|p| p.to_string_lossy().to_string()));
    let arg_refs: Vec<&str> = args.iter().map(String::as_str).collect();

    let stdout = subprocess::run_capture(&parser_bin_str, &arg_refs)?;
    let mut ir = Json::parse(&stdout).map_err(|e| format!("parsing hecks-parse chapter output for {chapter_name}: {e}"))?;
    optional_pass::run(&mut ir);
    Ok(crate::json::write(&ir))
}

fn run_codegen_full(codegen_bin: &Path, args: &[String]) -> Result<(), String> {
    let codegen_bin_str = codegen_bin.to_string_lossy().to_string();
    let mut full_args: Vec<String> = vec!["full".to_string()];
    full_args.extend(args.iter().cloned());
    let arg_refs: Vec<&str> = full_args.iter().map(String::as_str).collect();
    subprocess::run(&codegen_bin_str, &arg_refs)
}

fn remove_dir_if_exists(path: &Path) -> Result<(), String> {
    if path.exists() {
        std::fs::remove_dir_all(path).map_err(|e| format!("removing {}: {e}", path.display()))?;
    }
    Ok(())
}

/// `ensure_binaries_built!` (Ruby) — a plain `cargo build` (debug
/// profile, matching `PARSER_BIN`/`CODEGEN_BIN`'s own `target/debug/...`
/// paths) in each sibling crate directory, output suppressed unless it
/// fails.
fn ensure_binaries_built(parser_dir: &Path, codegen_dir: &Path) -> Result<(), String> {
    subprocess::cargo_build_quiet(parser_dir)?;
    subprocess::cargo_build_quiet(codegen_dir)?;
    Ok(())
}
