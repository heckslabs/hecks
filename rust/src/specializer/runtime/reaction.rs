//! Rust-native specializer for `rust/src/runtime/reaction.rs`.
//!
//! i728 runtime-as-bluebook strangler file-split (cluster 4b — Phase-3
//! reaction delivery). Thin per-file emitter : its HEADER const + a delegate
//! to the shared `split_file` helper, which builds the `impl Runtime { … }`
//! block from the `SplitMethod` rows whose `file` is `reaction`.
//!
//! [antibody-exempt: rust/src/specializer/runtime/reaction.rs — i728
//!  runtime-as-bluebook strangler file-split specializer. Same i80/i147
//!  kernel-floor retirement contract as its siblings ; retires at the i78
//!  meta-shape.]

use super::split_file;
use std::error::Error;
use std::path::Path;

const HEADER: &str = r#"//! Runtime Phase-3 reaction delivery — run the impure adapter edge + the
//! policy/PM/driven cascade for a dispatched command result, and drain the
//! reaction outbox to quiescence. GENERATED from codegen/runtime_shape (the
//! `SplitMethod` rows with file `reaction`) by the runtime-as-bluebook
//! strangler file-split. Do NOT hand-edit ; edit the shape + snippets and run
//! `storehouse specialize reaction --output rust/src/runtime/reaction.rs`.
//!
//! Inherent `impl Runtime` methods in a child module ; they reach Runtime's
//! private `resolve_*` / `drain_policies` helpers + the `outbox` field and the
//! pub `driven_adapter_resolver` module through child-module privacy + the
//! `super::*` glob. `react` / `react_ports` are `pub(super)` because mod.rs's
//! dispatch paths call them.
//!
//! [antibody-exempt: rust/src/runtime/reaction.rs — GENERATED output of the
//!  runtime_shape specializer (runtime-as-bluebook strangler file-split,
//!  cluster 4b). The bluebook shape is the source ; this .rs is a golden-gated
//!  build artifact, not hand-written. Retires at the i78 meta-shape.]

use super::*;
use std::collections::HashMap;

"#;

pub fn emit(repo_root: &Path) -> Result<String, Box<dyn Error>> {
    split_file::emit(repo_root, "reaction", HEADER)
}
