//! Library face of the crate, shared by the native/WASI binary and the rust/web browser cdylib.
//! Std-only, zero Cargo dependencies (ADR 0012); wasm-bindgen lives in rust/web.
pub mod generated;
pub mod kernel;
// Comment-only change under rust/src, to measure the first CI run after a Rust source change (third probe).

// Test-only: rust/codegen/src/exemplar.rs slices shapes out of this; never in a release build.
#[cfg(test)]
pub mod exemplar;
