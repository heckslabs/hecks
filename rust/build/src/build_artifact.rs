//! Runs `cargo build` for the generated domain crate, native or WASM.

use std::path::Path;

use crate::subprocess;

/// Runs `cargo build --release` in `rust_dir`, building the `default` feature that
/// `cargo_sync::run` just set.
pub fn build_native(rust_dir: &Path) -> Result<(), String> {
    println!("== cargo build --release (native) ==");
    subprocess::run_in(rust_dir, "cargo", &["build", "--release"])
}

/// Cross-compiles to `wasm32-wasip1` and copies the `.wasm` plus its `ir.json` sidecar
/// into `rust/dist/`.
///
/// Builds through `rustup run stable cargo`: a Homebrew `cargo` earlier on the path never
/// saw `rustup target add` and fails opaquely.
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
