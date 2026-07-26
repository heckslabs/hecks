//! ports - the impure edges, one folder each, mirroring lib/hecksagain/ports/.
//!
//! A port is the CONTRACT : the how-verb a bind hangs off an aggregate, and
//! whether the domain gets a value back or announces an event and waits. Each
//! folder holds the contract AND its execution - the resolution that turns a
//! declared bind into a live edge.
//!
//! A port NEVER names its adapters. The adapter declares the port, and that
//! inversion is what makes a new backend purely additive : nothing in here
//! changes when one arrives.
//!
//! Ruby has three ports and this side has two. EXTRACTION is the missing one,
//! and it is missing on purpose - see ports/loading/loading.rs for why an edge
//! that does not exist here should not be declared just to make two trees look
//! alike.

pub mod loading;
pub mod persistence;
