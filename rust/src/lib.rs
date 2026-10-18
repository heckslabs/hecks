//! Library face of the crate, shared by the native/WASI binary and the rust/web browser cdylib.
//! Std-only, zero Cargo dependencies (ADR 0012); wasm-bindgen lives in rust/web.

// Generated code keeps one shape for every domain, so a domain with no arms still has its `match`,
// a store still has its `new()`, and a chapter may hold an aggregate named like itself (identity::identity);
// clippy's complaints about that shape are not bugs to fix per file.
#[allow(
    clippy::match_single_binding,
    clippy::match_like_matches_macro,
    clippy::new_without_default,
    clippy::module_inception
)]
pub mod generated;
pub mod kernel;

// Test-only: rust/codegen/src/exemplar.rs slices shapes out of this; never in a release build.
// The files are templates with placeholder bodies, so they are neither formatted nor linted as code.
#[cfg(test)]
#[rustfmt::skip]
#[allow(
    clippy::match_single_binding,
    clippy::match_like_matches_macro,
    clippy::new_without_default,
    clippy::ptr_arg,
    clippy::borrow_deref_ref,
    unused_mut
)]
pub mod exemplar;
