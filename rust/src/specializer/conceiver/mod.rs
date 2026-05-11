//! Specializer modules for conceiver/ runner files.
//!
//! Each sibling here emits one `storehouse/src/conceiver/<name>.rs`
//! file byte-identical to its tracked source from a meta-shape
//! under `capabilities/conceiver_<name>_shape/` (or similar).
//!
//! [antibody-exempt: storehouse/src/specializer/conceiver/mod.rs —
//!  i147 wave 2 — module-declaration root for nested specializer
//!  targets, mirrors specializer/run_boot/mod.rs]

pub mod generator;
