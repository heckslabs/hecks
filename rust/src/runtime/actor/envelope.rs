//! Envelope — what the bus enqueues into a mailbox
//!
//! An envelope carries one event delivery : the source event,
//! a unique event_id for idempotency dedup, and the target actor
//! address. Handlers receive the envelope and decide what to do
//! with it. Cheap to clone (the inner Event clones its HashMap).
//!
//! Usage :
//!   let env = Envelope::new(event, event_id);
//!   mailbox.push(env);
//!
//! event_id is the bus's idempotency key. Two envelopes with the
//! same event_id arriving in the same mailbox produce ONE handler
//! invocation — the second is suppressed by the mailbox's bounded
//! seen-set (see mailbox.rs).

use crate::runtime::event_bus::Event;

#[derive(Debug, Clone)]
pub struct Envelope {
    pub event: Event,
    /// Bus-assigned unique id for idempotency dedup. When two envelopes
    /// arrive in the same mailbox with the same event_id, the second is
    /// dropped before the handler is invoked. Keeps event-replay /
    /// at-least-once delivery safe by construction.
    pub event_id: String,
}

impl Envelope {
    pub fn new(event: Event, event_id: impl Into<String>) -> Self {
        Envelope { event, event_id: event_id.into() }
    }
}
