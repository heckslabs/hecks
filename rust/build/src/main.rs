//! `hecks-build <domain> [--wasm] [--no-build] [--out <dir>]` compiles a domain's `.bluebook` to a binary.
//! `<domain>` is a domain directory such as `examples/pizzas`; `--wasm` also cross-compiles to
//! `wasm32-wasip1`, and `--no-build` generates source only.

mod build_artifact;
mod cargo_sync;
// The one JSON implementation, compiled from `hecks-codegen`'s own source: neither crate depends on
// the other, and a packaged workspace ships both side by side. This crate reads only part of it.
#[allow(dead_code)]
#[path = "../../codegen/src/json.rs"]
mod json;
mod lineage_pass;
mod pipeline;
mod reserved_names;
mod resolve;
mod root;
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

fn run(args: &[String]) -> Result<(), String> {
    let mut domain: Option<String> = None;
    let mut build_wasm = false;
    let mut no_build = false;
    let mut out_dir: Option<String> = None;

    let mut iter = args.iter();
    while let Some(arg) = iter.next() {
        match arg.as_str() {
            "--out" => out_dir = Some(iter.next().ok_or("--out needs a directory")?.clone()),
            "--wasm" => build_wasm = true,
            "--no-build" => no_build = true,
            other if !other.starts_with("--") && domain.is_none() => domain = Some(other.to_string()),
            other => return Err(format!("unrecognized argument {other:?} — usage: hecks-build <domain> [--wasm] [--no-build] [--out <dir>]")),
        }
    }

    let domain = domain.ok_or_else(|| "usage: hecks-build <domain> [--wasm] [--no-build] [--out <dir>]".to_string())?;
    let root = root::find()?;

    // `--out` generates the module tree into that directory only: no `Cargo.toml` rewrite, no
    // native or wasm build, so a `build.rs` can call it from inside a cargo build.
    let opts = pipeline::Options {
        build_native: !no_build && out_dir.is_none(),
        build_wasm: build_wasm && !no_build && out_dir.is_none(),
        out_dir: out_dir.map(std::path::PathBuf::from),
    };

    pipeline::run(&root, &domain, &opts)
}
