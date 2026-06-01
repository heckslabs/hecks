//! Actor-per-aggregate-instance — sprint 14 actor model quartet
//!
//! Each `(aggregate_type, aggregate_id)` pair has its own mailbox.
//! Events delivered to a mailbox process in FIFO order on a dedicated
//! OS thread ; different mailboxes process in parallel. A panic in one
//! mailbox does not poison the others ; the panicked mailbox is marked
//! poisoned, the runtime continues. Duplicate event-ids are deduped at
//! the mailbox boundary so handlers run once even if the bus emits twice.
//!
//! Four facets, one mechanism :
//! - actor-per-aggregate-instance — mailbox keyed by (type, id)
//! - async-event-delivery-bus     — emit is fire-and-forget enqueue
//! - per-actor-failure-isolation  — panic stays inside one mailbox
//! - causal-ordering-per-aggregate— FIFO per-mailbox is automatic
//!
//! The existing synchronous dispatch path is NOT replaced — it is
//! WRAPPED. Command dispatch still returns synchronously (sync feel).
//! What flows through the mailbox is event-driven cascade work — the
//! fan-out that follows a successful command. That gives parallelism
//! across aggregate instances without breaking the sync command contract.
//!
//! Usage :
//!   let mut registry = MailboxRegistry::new();
//!   registry.deliver(("Sprint".into(), "14".into()), envelope, handler);
//!   registry.drain_all();  // testing utility — block until idle
//!
//! See `runtime/event_bus.rs` for how the bus enqueues envelopes and
//! the four behaviors fixtures (`actor_model.behaviors`) for the
//! end-to-end smoke contracts each story flips on.

mod envelope;
mod mailbox;
mod registry;
mod snapshot;
mod supervisor;

pub use envelope::Envelope;
pub use mailbox::{Mailbox, MailboxStatus};
pub use registry::{MailboxRegistry, ActorAddress};
pub use snapshot::{MailboxStatusLabel, MailboxSummary};
pub use supervisor::SupervisorOutcome;

#[cfg(test)]
mod tests;
