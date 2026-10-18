//! Library face of the crate, shared by the native/WASI binary and the rust/web browser cdylib.
//! Std-only, zero Cargo dependencies (ADR 0012); wasm-bindgen lives in rust/web.

// Generated code keeps one shape for every domain, so a domain with no arms still has its `match`,
// a store still has its `new()`, a chapter may hold an aggregate named like itself
// (identity::identity), and every command gets the same signature whether or not it uses all of
// it. Clippy's complaints about that shape are not bugs to fix per file; the generators fix the
// ones that are real (see the emitters in rust/codegen/src).
#[allow(
    clippy::match_single_binding,
    clippy::match_like_matches_macro,
    clippy::new_without_default,
    clippy::module_inception,
    clippy::needless_pass_by_value,
    clippy::needless_pass_by_ref_mut,
    clippy::unused_self,
    clippy::unnecessary_wraps,
    clippy::trivially_copy_pass_by_ref,
    clippy::no_effect_underscore_binding,
    clippy::missing_const_for_fn,
    clippy::derive_partial_eq_without_eq,
    clippy::single_match_else,
    clippy::needless_continue,
    clippy::implicit_clone,
    clippy::assigning_clones,
    clippy::doc_link_with_quotes,
    clippy::redundant_closure_for_method_calls
)]
pub mod generated;
pub mod kernel;

// Test-only: rust/codegen/src/exemplar.rs slices shapes out of this; never in a release build.
// The files are templates with placeholder bodies, named after their placeholders, so they are
// neither formatted nor linted as code.
#[cfg(test)]
#[rustfmt::skip]
#[allow(
    clippy::match_single_binding,
    clippy::match_like_matches_macro,
    clippy::new_without_default,
    clippy::ptr_arg,
    clippy::borrow_deref_ref,
    clippy::needless_pass_by_value,
    clippy::needless_pass_by_ref_mut,
    clippy::unused_self,
    clippy::unnecessary_wraps,
    clippy::trivially_copy_pass_by_ref,
    clippy::no_effect_underscore_binding,
    clippy::missing_const_for_fn,
    clippy::derive_partial_eq_without_eq,
    clippy::use_self,
    clippy::uninlined_format_args,
    clippy::redundant_closure_for_method_calls,
    clippy::map_unwrap_or,
    clippy::doc_link_with_quotes,
    unused_mut
)]
pub mod exemplar;
