//! THE NEW PART — actually invoking `cargo build` for the domain's own
//! compiled artifact, native at minimum and optionally WASM. This is
//! what makes the whole pipeline end-to-end: `.bluebook` source in, a
//! compiled binary out, one command, zero Ruby anywhere in the chain —
//! `rust/project_rust_pipeline.rb` (the Ruby orchestrator this crate
//! replaces) stops one step short of this, at "generated Rust source
//! ready for `cargo build`", because its caller (`bin/project_rust`) is
//! itself a Ruby process and this repo's own separate `bin/project_wasm`
//! already does the WASM half by shelling out to `bin/project_rust`
//! first — so neither Ruby script actually needed to also invoke `cargo`
//! from inside itself for the same reason this crate does: for THEM,
//! Ruby is already running; for this crate, `cargo build` closing the
//! loop in-process is the entire point.

use std::path::Path;

use crate::subprocess;

/// `cargo build --release` in the `rust/` kernel crate directory — picks
/// up whatever `default` feature `cargo_sync::run` just set (the domain
/// this run targeted), matching a bare `cargo build`/`cargo test`'s own
/// behavior after `bin/project_rust` finishes, per that script's own
/// `Cargo.toml` comment.
pub fn build_native(rust_dir: &Path) -> Result<(), String> {
    println!("== cargo build --release (native) ==");
    subprocess::run_in(rust_dir, "cargo", &["build", "--release"])
}

/// `bin/project_wasm`'s own cross-compile step, ported verbatim: checks
/// `wasm32-wasip1` is installed (a real environment limitation this
/// crate reports rather than treats as a code bug when it isn't), builds
/// through `rustup run stable cargo ...` rather than a bare `cargo`
/// (that script's own comment: a Homebrew `cargo`/`rustc` earlier on
/// PATH never saw `rustup target add` and fails opaquely otherwise),
/// then copies the artifact plus its `ir.json` sidecar into `rust/dist/`
/// under the domain's own name.
pub fn build_wasm(root: &Path, rust_dir: &Path, target_mod_name: &str) -> Result<(), String> {
    let installed = subprocess::run_capture("rustup", &["target", "list", "--installed"])
        .map_err(|e| format!("checking installed rustup targets: {e}"))?;
    if !installed.lines().any(|l| l.trim() == "wasm32-wasip1") {
        return Err(
            "wasm32-wasip1 isn't installed for this toolchain (environment limitation, not a code bug) — install it once with:\n\n    rustup target add wasm32-wasip1\n\nthen re-run hecks-build --wasm.".to_string(),
        );
    }

    println!("== cargo build --release --target wasm32-wasip1 (via rustup run stable) ==");
    subprocess::run_in(rust_dir, "rustup", &["run", "stable", "cargo", "build", "--release", "--target", "wasm32-wasip1"])?;

    let dist_dir = root.join("rust/dist");
    std::fs::create_dir_all(&dist_dir).map_err(|e| format!("creating {}: {e}", dist_dir.display()))?;

    let built = rust_dir.join("target/wasm32-wasip1/release/rust.wasm");
    let out = dist_dir.join(format!("{target_mod_name}.wasm"));
    std::fs::copy(&built, &out).map_err(|e| format!("copying {} to {}: {e}", built.display(), out.display()))?;
    println!("wrote {}", out.display());

    let ir_json = root.join("rust/src/generated").join(target_mod_name).join("ir.json");
    if ir_json.is_file() {
        let ir_out = dist_dir.join(format!("{target_mod_name}.ir.json"));
        std::fs::copy(&ir_json, &ir_out).map_err(|e| format!("copying {} to {}: {e}", ir_json.display(), ir_out.display()))?;
        println!("wrote {}", ir_out.display());
    }

    Ok(())
}
