//! Rust-native specializer for `rust/src/runtime/persistence_resolution.rs`.
//!
//! i728 runtime-as-bluebook strangler — the FILE-SPLIT (machinery cost #2).
//! Where `root.rs` emits sections INTO `runtime/mod.rs`, this emits a kernel
//! concern OUT of it into its own generated, golden-gated file. The
//! persistence-resolution `impl Runtime` methods move here ; mod.rs loses
//! them entirely (no 2nd copy, no drift surface). Mirrors
//! `runtime/command_dispatch.rs` : a HEADER const + a row walk.
//!
//! Design : one `impl Runtime { … }` block built from `ResolutionMethod`
//! rows whose `file` attr is `persistence_resolution`, in `order` ascending,
//! verbatim_method bodies separated by one blank line. Adding / moving a
//! resolution method is a fixture row + snippet pair, not a mod.rs hand-edit.
//!
//! Usage :
//!   let rust = runtime::persistence_resolution::emit(repo_root)?;
//!   print!("{}", rust);
//!
//! [antibody-exempt: rust/src/specializer/runtime/persistence_resolution.rs —
//!  i728 runtime-as-bluebook strangler file-split specializer. Same i80/i147
//!  kernel-floor retirement contract as its command_dispatch / root siblings ;
//!  retires at the i78 meta-shape.]

use super::split_file;
use std::error::Error;
use std::path::Path;

const HEADER: &str = r#"//! Runtime persistence resolution (i728) — the backend-map projection read
//! + the dormant is-wired check. GENERATED from codegen/runtime_shape (the
//! `ResolutionMethod` rows + snippets) by the runtime-as-bluebook strangler
//! file-split. Do NOT hand-edit ; edit the shape + snippets and run
//! `storehouse specialize persistence_resolution --output
//! rust/src/runtime/persistence_resolution.rs`.
//!
//! Inherent `impl Runtime` methods in a child module : child modules see the
//! parent's private fields + helpers, so these reach `self.repositories` /
//! `self.hecksagons` / `repo_key` directly.
//!
//! [antibody-exempt: rust/src/runtime/persistence_resolution.rs — GENERATED
//!  output of the runtime_shape specializer (runtime-as-bluebook strangler
//!  file-split, i728). The bluebook shape is the source ; this .rs is a
//!  golden-gated build artifact, not hand-written. Retires at the i78
//!  meta-shape like its specializer siblings.]

use super::*;

// apply_sqlite_persistence is the only #[cfg(not(wasm32))] method here and the
// only user of these two ; gate the imports to match so the wasm build carries
// no unused-import warning. Everything else resolves through the `super::*`
// glob (BackendInfo, LazyRepository, repo_key, the pub sqlite_* modules).
#[cfg(not(target_arch = "wasm32"))]
use std::collections::HashMap;
#[cfg(not(target_arch = "wasm32"))]
use super::lazy_repository;

"#;

pub fn emit(repo_root: &Path) -> Result<String, Box<dyn Error>> {
    split_file::emit(repo_root, "persistence_resolution", HEADER)
}
