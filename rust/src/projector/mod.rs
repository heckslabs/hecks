//! projector - sending the domain elsewhere.
//!
//! Mirrors lib/hecksagain/projector/ on the Ruby side.
//!
//!   ruby exporter.rb  <->  rust ir_json.rs   the IR as this runtime reads it
//!                          rust dump.rs      the CANONICAL IR - Hecks's parity
//!                                            contract, brought over unedited
//!
//! dump.rs has no Ruby twin yet: its counterpart is Hecks's canonical_ir.rb,
//! which walks a Ruby BluebookModel this project has not brought over. Until it
//! does, `--canonical` is half a contract.

pub mod dump;
pub mod ir_json;
