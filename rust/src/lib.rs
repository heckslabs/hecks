//! Library face of the crate, shared by the native/WASI binary and the rust/web browser cdylib.
//! Std-only, zero Cargo dependencies (ADR 0012); wasm-bindgen lives in rust/web.
pub mod generated;
pub mod kernel;

// Test-only: rust/project/exemplar.rb slices shapes out of this; never in a release build.
#[cfg(test)]
pub mod exemplar;
