// THE LIBRARY FACE OF THIS CRATE — split out from main.rs so a second,
// separate compilation target (rust/web, the wasm-bindgen browser
// projection — docs/decisions/0015-wasm-bindgen-browser-projection.md)
// can depend on `kernel`/`generated` as an ordinary path dependency
// instead of duplicating them. Carries zero behavior of its own: same
// `mod` list main.rs held before this split, nothing added, nothing
// domain-specific. The native/WASI binary (main.rs) and the browser
// cdylib (rust/web/src/lib.rs) both compile this SAME source unchanged —
// the std-only, zero-Cargo-dependency constraint 0012 set for this crate
// still holds here; wasm-bindgen is a dependency of rust/web, never of
// this crate.
pub mod generated;
pub mod kernel;

// Real, `cargo test`-checked Rust that rust/project/exemplar.rb slices
// shapes out of — see rust/src/exemplar/mod.rs's own header. Test-only:
// never part of a release/Lambda/WASM build.
#[cfg(test)]
pub mod exemplar;
