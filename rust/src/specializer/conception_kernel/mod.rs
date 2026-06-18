//! Specializer modules for `conception_kernel/` DATA-layer files.
//!
//! Each sibling emits one `rust/src/conception_kernel/<name>.rs` as a genuine
//! data-driven projection of the conception's data layer
//! (behaviors_conception.bluebook) — the match arms / table rows are GENERATED
//! from fixtures, NOT relocated verbatim. The conception explicitly rejects the
//! section-as-snippet chop for the conceiver (it "captures no knowledge") ; this
//! is the opposite — the type->literal and precondition-taxonomy knowledge lives
//! as data and the Rust is synthesized from it. The recursive PLANNER
//! (planner.rs) is NOT projected here : the conception fences it as the kernel
//! interpreter that EXECUTES the grammar, not a specializer target.

pub mod sample;
