//! adapters - the two sides of the hexagon, mirroring
//! lib/hecksagain/adapters/.
//!
//! driven/  edges that LEAVE the domain : the domain composes a call and the
//!          adapter runs it.
//! driving/ the inverse - an external clock or caller reaching IN to dispatch.
//!          Empty until the first driver is declared, which is the honest state
//!          rather than a placeholder.
//!
//! The heavy, swappable backends live in their OWN CRATES (sqlite/) rather than
//! here : a port may not depend on an adapter, and Cargo enforces that as a
//! dependency cycle. Same side of the hexagon, different compilation unit.

pub mod driven;
