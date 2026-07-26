//! storehouse - the library half of the hecksagain runtime.
//!
//! Named `storehouse` on purpose. The adapters cherry-picked from Hecks import
//! `storehouse::runtime::{PersistenceAdapter, Value, AggregateState}` and
//! `storehouse::ir`, so exposing the crate under that name is what lets them
//! come over UNEDITED. Renaming their imports would have been the first edit,
//! and the first edit is how a cherry-pick becomes a fork.
//!
//! THE FOLDERS MIRROR THE RUBY SIDE, so the two implementations can be read
//! against each other:
//!
//!   lib/hecksagain/bluebook/    <->  src/bluebook/
//!   lib/hecksagain/runtime/     <->  src/runtime/
//!   lib/hecksagain/projector/   <->  src/projector/
//!   lib/hecksagain/adapters/    <->  sqlite/ (its own crate - the port may
//!                                    not depend on an adapter, and Cargo
//!                                    enforces that as a dependency cycle)
//!
//! That mirroring pulls against re-syncing cherry-picks, which is easiest when
//! paths match HECKS. The resolution: files keep Hecks's NAMES and CONTENTS and
//! only the folder moved, and every `crate::...` path a copied file uses is
//! re-exported below. So a copied file still resolves `crate::ir`,
//! `crate::heki`, `crate::world::parser_mcp` exactly as it did in Hecks, and
//! not one of them needed an edit.

pub mod bluebook;
pub mod projector;
pub mod runtime;

#[allow(dead_code)]
pub mod clock;
#[allow(dead_code)]
pub mod heki;
#[allow(dead_code)]
pub mod util;

pub mod wiring;

#[cfg(test)]
mod wiring_tests;

// ---------------------------------------------------------------------------
// Crate-root aliases.
//
// The cherry-picked files reach for `crate::ir`, `crate::pattern_subset`,
// `crate::hecksagon_ir`, `crate::world::...` - the paths they had in Hecks,
// where these sat at the crate root. Re-exporting them here keeps every one of
// those paths valid while the FILES live in mirrored folders. This is the seam
// that lets the layout serve the reader without forking the source.
// ---------------------------------------------------------------------------
pub use bluebook::hecksagon_helpers;
pub use bluebook::hecksagon_ir;
pub use bluebook::hecksagon_parser;
pub use bluebook::ir;
pub use bluebook::parse_blocks;
pub use bluebook::parser;
pub use bluebook::parser_helpers;
pub use bluebook::pattern_subset;
pub use bluebook::world;

// The interpreters kept Hecks's internal names too (interp_expr / interp_givens
// are resolver / evaluator here, matching the Ruby files they twin).
pub use bluebook::expression::evaluator as interp_givens;
pub use bluebook::expression::resolver as interp_expr;
pub use runtime::dispatcher;
pub use runtime::mutations as interp_mutations;
pub use runtime::value_bridge;

pub use projector::dump;
pub use projector::ir_json;
