//! Browser projection (ADR 0015): a separate cdylib crate so `rust` stays std-only (ADR 0012).
//! `dispatch` takes and returns the same JSON as `rust::kernel::cli::run`.
use wasm_bindgen::prelude::*;

#[wasm_bindgen]
pub fn dispatch(input: &str) -> String {
    rust::kernel::cli::run(input)
}
