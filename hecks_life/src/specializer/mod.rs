//! Rust-native specializer driver — the destination for the i51
//! Phase D Ruby → Rust migration of `lib/hecks_specializer/`.
//!
//! Each module under `specializer::` owns one target's emission logic,
//! exposing `emit(repo_root: &Path) -> Result<String, _>`. The
//! top-level `emit(target, repo_root)` dispatcher matches a target
//! name to its module, mirroring `Hecks::Specializer.emit(:name)` on
//! the Ruby side.
//!
//! Phase D policy — both runtimes MUST produce byte-identical output
//! for every ported target until the migration completes. Golden
//! tests in `hecks_life/tests/specializer_golden_test.rs` enforce
//! this for each port.
//!
//! Usage (from main.rs):
//!   let rust = specializer::emit("validator_warnings", &repo_root)?;
//!   print!("{}", rust);

use std::error::Error;
use std::path::Path;

pub mod util;
pub mod validator_warnings;

/// Dispatch by target name. Phase D pilot: `validator_warnings` only.
/// Every subsequent port adds one match arm here.
pub fn emit(target: &str, repo_root: &Path) -> Result<String, Box<dyn Error>> {
    match target {
        "validator_warnings" => validator_warnings::emit(repo_root),
        other => Err(format!(
            "unknown specializer target: {}. Known: validator_warnings",
            other
        )
        .into()),
    }
}
