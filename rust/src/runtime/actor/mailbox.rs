//! Mailbox — per-actor FIFO + bounded idempotency seen-set
//!
//! One mailbox per `(aggregate_type, aggregate_id)` pair. Envelopes
//! pushed to the mailbox arrive in dispatch order ; the drain loop
//! pops them one at a time (causal-ordering-per-aggregate). The
//! mailbox carries a bounded LRU of recently-seen event_ids — a
//! second arrival with the same id is dropped before the handler
//! runs (idempotency by construction).
//!
//! When a handler panics the mailbox's `status` flips to Poisoned.
//! Subsequent pushes still enqueue (so the audit trail captures
//! attempts) but the drain loop stops invoking the handler. Other
//! mailboxes are unaffected.
//!
//! Usage :
//!   let mut mb = Mailbox::new();
//!   if mb.push(envelope) {           // false = duplicate, suppressed
//!       mb.drain(|env| handler(env));
//!   }
//!
//! The seen-set is bounded to `SEEN_CAPACITY` ids ; older ids age out
//! FIFO. That bounds the per-mailbox memory cost while keeping the
//! dedup window long enough to absorb realistic bus replay storms.

use super::Envelope;
use std::collections::VecDeque;

/// Bound on the per-mailbox seen-set. 256 is enough for replay storms
/// without pinning unbounded memory ; chosen as a round-power-of-two
/// matching the historical mpsc default queue depth.
pub const SEEN_CAPACITY: usize = 256;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MailboxStatus {
    /// Healthy ; drain loop invokes handler on each pop.
    Live,
    /// A handler panicked ; drain loop stops invoking the handler on
    /// this mailbox. The mailbox stays addressable so post-mortem
    /// inspection (queue depth, last_panic) is still possible.
    Poisoned,
}

pub struct Mailbox {
    queue: VecDeque<Envelope>,
    seen: VecDeque<String>,
    pub status: MailboxStatus,
    pub last_panic: Option<String>,
    pub handled_count: usize,
    pub dropped_duplicates: usize,
}

impl Mailbox {
    pub fn new() -> Self {
        Mailbox {
            queue: VecDeque::new(),
            seen: VecDeque::with_capacity(SEEN_CAPACITY),
            status: MailboxStatus::Live,
            last_panic: None,
            handled_count: 0,
            dropped_duplicates: 0,
        }
    }

    /// Enqueue an envelope. Returns `false` when the event_id was
    /// already seen — the envelope is dropped, dropped_duplicates is
    /// incremented, the handler will never run for this delivery.
    /// Returns `true` when the envelope is fresh and now sits in the
    /// FIFO queue waiting for the drain loop.
    pub fn push(&mut self, env: Envelope) -> bool {
        if self.has_seen(&env.event_id) {
            self.dropped_duplicates += 1;
            return false;
        }
        self.note_seen(env.event_id.clone());
        self.queue.push_back(env);
        true
    }

    /// Drain every queued envelope through the handler. Stops invoking
    /// the handler when the mailbox is Poisoned (envelopes drain to
    /// /dev/null for audit symmetry — they were ALREADY enqueued, the
    /// failure happened on a sibling delivery). Returns the count of
    /// successfully-handled envelopes.
    pub fn drain<F: FnMut(&Envelope)>(&mut self, mut handler: F) -> usize {
        let mut handled = 0;
        while let Some(env) = self.queue.pop_front() {
            if self.status == MailboxStatus::Poisoned {
                continue;
            }
            handler(&env);
            handled += 1;
            self.handled_count += 1;
        }
        handled
    }

    /// Pop one envelope without invoking a handler. Used by the
    /// supervisor's catch_unwind wrapper so the supervisor can
    /// observe panic outcomes and flip status without re-entering
    /// `drain`'s borrow.
    pub fn pop(&mut self) -> Option<Envelope> {
        self.queue.pop_front()
    }

    /// Mailbox depth — exposed for the `storehouse mailboxes` debug
    /// command (sprint 14 follow-up). Always read-only.
    pub fn depth(&self) -> usize { self.queue.len() }

    // ── `storehouse mailboxes` debug accessors ───────────────────────
    //
    // These getters expose the four observability axes the debug CLI
    // renders : queue depth, lifecycle status, events-processed count,
    // and (when poisoned) the recorded panic reason. They are read-only
    // alternates to the pub fields so external callers don't take a
    // direct reference into the mailbox interior — handy when the
    // mailbox eventually moves behind an Arc<Mutex<_>>-only surface.

    /// Number of envelopes waiting in the FIFO queue. Same value as
    /// `depth()` ; named to match the debug-CLI vocabulary.
    pub fn queue_depth(&self) -> usize { self.queue.len() }

    /// Lifecycle status (Live | Poisoned). Read-only.
    pub fn status(&self) -> MailboxStatus { self.status }

    /// Total envelopes the handler has run for this mailbox since boot.
    /// Sibling of `dropped_duplicates` (suppressed at the boundary) and
    /// of the live queue depth.
    pub fn events_processed_count(&self) -> usize { self.handled_count }

    /// Last recorded panic reason, if this mailbox is poisoned. Returns
    /// `None` for a Live mailbox or a Poisoned mailbox that recorded no
    /// reason (defensive — `mark_poisoned` always supplies one).
    pub fn last_error(&self) -> Option<&str> { self.last_panic.as_deref() }

    pub fn mark_poisoned(&mut self, reason: impl Into<String>) {
        self.status = MailboxStatus::Poisoned;
        self.last_panic = Some(reason.into());
    }

    pub fn note_handled(&mut self) { self.handled_count += 1; }

    fn has_seen(&self, event_id: &str) -> bool {
        self.seen.iter().any(|id| id == event_id)
    }

    fn note_seen(&mut self, event_id: String) {
        if self.seen.len() >= SEEN_CAPACITY {
            self.seen.pop_front();
        }
        self.seen.push_back(event_id);
    }
}

impl Default for Mailbox {
    fn default() -> Self { Self::new() }
}
