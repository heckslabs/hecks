//! Specializer modules for runtime/ kernel files.
//!
//! Each sibling here emits one `storehouse/src/runtime/<name>.rs`
//! file byte-identical to its tracked source from a meta-shape
//! under `codegen/<name>_shape/` (or similar).
//!
//! Mirrors `specializer/run_boot/mod.rs` and
//! `specializer/conceiver/mod.rs` — module-declaration root for
//! nested specializer targets that live under a source subtree.
//!
//! [antibody-exempt: storehouse/src/specializer/runtime/mod.rs —
//!  i147 wave 3-A — module-declaration root for nested specializer
//!  targets, mirrors specializer/run_boot/mod.rs and
//!  specializer/conceiver/mod.rs]

pub mod aggregate_state;
pub mod command_dispatch;
pub mod interpreter;
pub mod persistence_resolution;
pub mod root;
