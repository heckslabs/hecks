//! Rust-native specializer driver — the final destination of the i51
//! Futamura arc.
//!
//! Phase E completed: the Ruby `lib/hecks_specializer/` modules, the
//! `bin/specialize` driver, and the Ruby-emitting Rust meta-specializers
//! have all been deleted. This module is now the sole codegen path for
//! every Rust target under `storehouse/src/*.rs`. Each sibling module
//! owns one target's emission logic and exposes
//! `emit(repo_root: &Path) -> Result<String, _>`.
//!
//! Golden tests in `storehouse/tests/specializer_golden_test.rs`
//! enforce byte-identity against the tracked `.rs` sources.
//!
//! Usage (from main.rs):
//!   let rust = specializer::emit("validator_warnings", &repo_root)?;
//!   print!("{}", rust);

use std::error::Error;
use std::path::Path;

