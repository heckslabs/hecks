//! `hecks-build` — Stage 8 CAPSTONE (a follow-up to
//! `/Users/christopheryoung/.claude/plans/sequential-petting-whale.md`,
//! continuing directly from that plan's own Stage 8, which landed as
//! `rust/project_rust_pipeline.rb` — an all-Rust PARSE+CODEGEN pipeline
//! that was still itself a Ruby process, opt-in behind
//! `HECKS_PARSER=rust HECKS_CODEGEN=rust bin/project_rust <domain>`).
//!
//! THIS CRATE DOES THE SAME JOB, but is itself a compiled Rust binary —
//! a domain's `.bluebook` source goes from disk to a compiled artifact
//! with NO Ruby process involved anywhere in the chain, not even for
//! orchestration. `rust/project_rust_pipeline.rb`'s own header is the
//! literal specification this crate ports (`src/pipeline.rs` mirrors its
//! `RustProjectPipeline.call` body step for step); read that file's own
//! extensive comments for the full reasoning behind each step, which
//! this crate deliberately does NOT re-derive, only re-implements.
//!
//! ARCHITECTURE (decided, not re-litigated here): this crate calls the
//! EXISTING `hecks-parse` (`rust/parser/`) and `hecks-codegen`
//! (`rust/codegen/`) binaries as SUBPROCESSES
//! (`std::process::Command`, via `src/subprocess.rs`) — the same way
//! `rust/project_rust_pipeline.rb` shells out to them via
//! `Open3.capture3`/`system` today. Neither sibling crate is
//! restructured into a library or merged into this one: both stay
//! exactly as they are, proven byte-exact against Ruby's own reference
//! implementation by `spec/parser_parity_spec.rb`/`spec/codegen_parity_
//! spec.rb`, and untouched by this work (`git diff --stat` against this
//! crate's own base commit is scoped to `rust/build/` and new spec
//! files only).
//!
//! THE ONE GENUINELY NEW PIECE OF LOGIC (beyond pure orchestration):
//! `src/optional_pass.rs`, a Rust port of `RustProjection::Projector.
//! mark_append_optional_fields!` (`rust/project/mutations.rb`) — see
//! that module's own header for the full derivation and how it's
//! verified.
//!
//! Usage:
//!
//!   hecks-build <domain> [--wasm] [--no-build]
//!
//! `<domain>` is a path to a domain's own directory (e.g.
//! `examples/pizzas`, `examples/banking`), the same argument shape
//! `bin/project_rust <domain>` already takes — resolved relative to the
//! CURRENT DIRECTORY, exactly like the Ruby original (this crate's own
//! `src/root.rs` separately locates the hecks REPO root, by walking
//! up from the current directory looking for `hecks.gemspec`, for
//! everything else it needs: `rust/parser`, `rust/codegen`, `rust/src/
//! generated`, `rust/Cargo.toml`, `lib/hecks/framework/bluebook`,
//! `lib/hecks/language/bluebook`).
//!
//! `--wasm` additionally cross-compiles for `wasm32-wasip1` (mirroring
//! `bin/project_wasm`'s own invocation) once the native build succeeds.
//! `--no-build` skips BOTH `cargo build` steps for the domain's own
//! compiled artifact, generating source only — useful for fast,
//! repeated differential verification against the existing Ruby
//! pipelines, which never build the domain artifact themselves either.
//! Native `cargo build --release` runs by default (no flag needed): the
//! whole point of this crate over the Ruby-orchestrated opt-in path is
//! that a plain `hecks-build <domain>` is genuinely end-to-end, bluebook
//! in, compiled binary out, one command.

//!
//! `--ir-dir <dir>` (ADR 0054a, B3) skips `hecks-parse` entirely and
//! generates from IR someone else already built: `<dir>/meta.json`,
//! `<dir>/target.json`, and `<dir>/chapters/*.json` (sorted; each
//! attached chapter, in the order its IR should be merged). This is how
//! `bin/project_rust` generates by default: Ruby still builds the
//! canonical IR (`Exporter.call` plus the `lineage`/`persistence`/
//! `translations`/`source_text` keys), this crate does everything after
//! that. The append-optional pass still runs here (it's the IR
//! derivation `rust/project`'s generator applied in place); the lineage
//! pass doesn't (the given target IR already carries `lineage`).
//!
//! `--root <path>` names the hecks repo root instead of walking up from
//! the current directory; `--rust-dir <path>` names the crate to project
//! into (default `<root>/rust`) — `bin/project_rust`'s `HECKS_RUST_DIR`.

mod build_artifact;
mod cargo_sync;
mod fsutil;
mod json;
mod lineage_pass;
mod optional_pass;
mod pipeline;
mod resolve;
mod root;
mod sidecars;
mod subprocess;
mod tmp;

use std::process::ExitCode;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match run(&args) {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) => {
            eprintln!("hecks-build: {message}");
            ExitCode::from(1)
        }
    }
}

const USAGE: &str = "usage: hecks-build <domain> [--wasm] [--no-build] [--ir-dir <dir>] [--root <path>] [--rust-dir <path>]";

fn run(args: &[String]) -> Result<(), String> {
    let mut domain: Option<String> = None;
    let mut build_wasm = false;
    let mut no_build = false;
    let mut ir_dir: Option<std::path::PathBuf> = None;
    let mut root_arg: Option<std::path::PathBuf> = None;
    let mut rust_dir: Option<std::path::PathBuf> = None;

    let mut iter = args.iter();
    while let Some(arg) = iter.next() {
        match arg.as_str() {
            "--wasm" => build_wasm = true,
            "--no-build" => no_build = true,
            flag @ ("--ir-dir" | "--root" | "--rust-dir") => {
                let value = iter.next().ok_or_else(|| format!("{flag} needs a value — {USAGE}"))?;
                let slot = match flag {
                    "--ir-dir" => &mut ir_dir,
                    "--root" => &mut root_arg,
                    _ => &mut rust_dir,
                };
                *slot = Some(std::path::PathBuf::from(value));
            }
            other if !other.starts_with("--") && domain.is_none() => domain = Some(other.to_string()),
            other => return Err(format!("unrecognized argument {other:?} — {USAGE}")),
        }
    }

    let domain = domain.ok_or_else(|| USAGE.to_string())?;
    let root = match root_arg {
        Some(path) => path,
        None => root::find()?,
    };

    let opts = pipeline::Options { build_native: !no_build, build_wasm: build_wasm && !no_build, ir_dir, rust_dir };

    pipeline::run(&root, &domain, &opts)
}
