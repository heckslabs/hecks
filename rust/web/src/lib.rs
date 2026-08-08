// THE BROWSER PROJECTION — docs/decisions/0015-wasm-bindgen-browser-projection.md.
// A separate crate on purpose, not a second `cargo build --target` of
// `rust`'s own binary (contrast bin/project_wasm, which cross-compiles
// `rust/src/main.rs` unchanged for wasm32-wasip1): a wasm-bindgen build
// needs a `cdylib` crate-type and the `wasm-bindgen` crate itself, and
// 0012 deliberately kept `rust` std-only with zero Cargo dependencies so
// the native binary and the WASI module stay that way. This crate is
// where that dependency lives instead — `rust` (this crate's own path
// dependency) is untouched by it.
//
// One export, mirroring `rust/src/kernel/cli.rs::run` exactly: JSON in
// (`{"steps": [...]}`), JSON out (`{"instances", "events", "refusals"}`)
// — the SAME contract bin/rust_conformance and bin/project_wasm's WASI
// module already speak, just called as a JS function instead of piped
// over stdin/stdout. No browser-specific API shape beyond that (no
// per-era module selection, no host-adapter import boundary) — those
// remain open, exactly as 0012 flagged them.
use wasm_bindgen::prelude::*;

#[wasm_bindgen]
pub fn dispatch(input: &str) -> String {
    rust::kernel::cli::run(input)
}
