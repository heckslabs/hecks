//! Rust-native specializer for `rust/src/runtime/event_driving.rs`.
//!
//! i728 runtime-as-bluebook strangler file-split (cluster 4 — event/outbox
//! driving). Thin per-file emitter : its HEADER const + a delegate to the
//! shared `split_file` helper, which builds the `impl Runtime { … }` block from
//! the `SplitMethod` rows whose `file` is `event_driving`.
//!
//! [antibody-exempt: rust/src/specializer/runtime/event_driving.rs — i728
//!  runtime-as-bluebook strangler file-split specializer. Same i80/i147
//!  kernel-floor retirement contract as its siblings ; retires at the i78
//!  meta-shape.]

use super::split_file;
use std::error::Error;
use std::path::Path;

const HEADER: &str = r#"//! Runtime event driving (Sprint 14) — the event-advancement surface OUTSIDE
//! the main dispatch path : the actor-mailbox enqueue/drain and the cron-tick
//! firing. GENERATED from codegen/runtime_shape (the `SplitMethod` rows with
//! file `event_driving`) by the runtime-as-bluebook strangler file-split. Do
//! NOT hand-edit ; edit the shape + snippets and run `storehouse specialize
//! event_driving --output rust/src/runtime/event_driving.rs`.
//!
//! Inherent `impl Runtime` methods in a child module ; reach Runtime's private
//! fields (mailbox_registry, event_bus, mailbox_drained) and the pub `actor` /
//! `driving_adapter_resolver` modules through the `super::*` glob.
//!
//! [antibody-exempt: rust/src/runtime/event_driving.rs — GENERATED output of
//!  the runtime_shape specializer (runtime-as-bluebook strangler file-split,
//!  cluster 4). The bluebook shape is the source ; this .rs is a golden-gated
//!  build artifact, not hand-written. Retires at the i78 meta-shape.]

use super::*;

"#;

pub fn emit(repo_root: &Path) -> Result<String, Box<dyn Error>> {
    split_file::emit(repo_root, "event_driving", HEADER)
}
