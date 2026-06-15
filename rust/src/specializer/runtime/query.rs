//! Rust-native specializer for `rust/src/runtime/query.rs`.
//!
//! i728 runtime-as-bluebook strangler file-split (cluster 7 — the
//! context-qualified read side). Thin per-file emitter : its HEADER const + a
//! delegate to the shared `split_file` helper.
//!
//! [antibody-exempt: rust/src/specializer/runtime/query.rs — i728
//!  runtime-as-bluebook strangler file-split specializer. Same i80/i147
//!  kernel-floor retirement contract as its siblings ; retires at the i78
//!  meta-shape.]

use super::split_file;
use std::error::Error;
use std::path::Path;

const HEADER: &str = r#"//! Runtime context-qualified read side — the (context, name) lookups that
//! disambiguate same-name aggregates across bluebooks (the i142
//! Context.Aggregate.query frame). GENERATED from codegen/runtime_shape (the
//! `SplitMethod` rows with file `query`) by the runtime-as-bluebook strangler
//! file-split. Do NOT hand-edit ; edit the shape + snippets and run
//! `storehouse specialize query --output rust/src/runtime/query.rs`.
//!
//! Inherent `impl Runtime` methods in a child module ; reach Runtime's private
//! repositories + the `repo_key` / `AggregateState` / `Value` / `WhereOp`
//! names through child-module privacy + the `super::*` glob.
//!
//! [antibody-exempt: rust/src/runtime/query.rs — GENERATED output of the
//!  runtime_shape specializer (runtime-as-bluebook strangler file-split,
//!  cluster 7). The bluebook shape is the source ; this .rs is a golden-gated
//!  build artifact, not hand-written. Retires at the i78 meta-shape.]

use super::*;

"#;

pub fn emit(repo_root: &Path) -> Result<String, Box<dyn Error>> {
    split_file::emit(repo_root, "query", HEADER)
}
