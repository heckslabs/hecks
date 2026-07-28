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
//!   lib/hecksagain/ports/       <->  src/ports/
//!   lib/hecksagain/adapters/    <->  src/adapters/  +  sqlite/ (its own crate
//!                                    - a port may not depend on an adapter,
//!                                    and Cargo enforces that as a dependency
//!                                    cycle. Same side of the hexagon, a
//!                                    different compilation unit.)
//!
//! One folder per port and per adapter, each named for what it holds. An adapter
//! does NOT live inside its port : the port must never name its adapters, and
//! that inversion is what makes a new backend purely additive.
//!
//! Ruby declares THREE ports, this side two. Extraction is absent on purpose -
//! Ruby must recover a predicate's source from a Proc that already swallowed it,
//! so it re-reads the file with Prism ; this side reads the .bluebook as
//! text and never loses it. An edge that does not exist should not be declared
//! to make two trees look alike.
//!
//! That mirroring pulls against re-syncing cherry-picks, which is easiest when
//! paths match HECKS. The resolution: files keep Hecks's NAMES and CONTENTS and
//! only the folder moved, and every `crate::...` path a copied file uses is
//! re-exported below. So a copied file still resolves `crate::ir`,
//! `crate::heki`, `crate::world::parser_mcp` exactly as it did in Hecks, and
//! not one of them needed an edit.

pub mod adapters;
pub mod bluebook;
pub mod ports;
pub mod projector;
pub mod runtime;

#[allow(dead_code)]
pub mod clock;
// The naming rule, at the kernel floor beside clock and util because every
// layer above needs it — the parser to name an attribute, the runtime to key a
// reference, the adapters to name a file and a table. One rule, one module.
pub mod naming;
#[allow(dead_code)]
pub mod util;

// ---------------------------------------------------------------------------
// Crate-root aliases.
//
// The cherry-picked files reach for `crate::ir`, `crate::pattern_subset`,
// `crate::hecksagon_ir`, `crate::world::...` - the paths they had in Hecks,
// where these sat at the crate root. Re-exporting them here keeps every one of
// those paths valid while the FILES live in mirrored folders. This is the seam
// that lets the layout serve the reader without forking the source.
// ---------------------------------------------------------------------------
// `crate::heki` and `storehouse::heki` stay valid though the file moved into its
// adapter folder — the sqlite crate imports it by that path, and a cherry-picked
// file that had to edit its imports would be a fork rather than a copy.
pub use adapters::driven::heki;

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
