//! MailboxSummary — read-only snapshot row for the `storehouse mailboxes`
//! debug command (sprint 14 — story `storehouse-actors-debug-command`)
//!
//! `Mailboxes::snapshot()` returns one of these per registered
//! mailbox, locking each Mailbox just long enough to copy the four
//! observability axes (status, queue depth, handled count, last error).
//! The CLI consumes the Vec without holding any of the Mailboxes table's
//! mutexes — render is fully decoupled from drain.
//!
//! Usage :
//!   let rows = mailboxes.snapshot();
//!   for row in &rows { println!("{} {} {:?}", row.aggregate_type, row.aggregate_id, row.status); }
//!
//! The struct exposes a `to_json` helper that returns a `serde_json::Value`
//! so the CLI's `--json` flag can dump it verbatim. `status` serializes
//! as the lowercase tag ("live" / "poisoned") for tooling-stable
//! consumption — the runtime enum stays internal.

use super::{ActorAddress, Mailbox, Mailboxes, MailboxStatus};

#[derive(Debug, Clone)]
pub struct MailboxSummary {
    pub aggregate_type: String,
    pub aggregate_id: String,
    pub status: MailboxStatusLabel,
    pub queue_depth: usize,
    pub events_processed: usize,
    pub dropped_duplicates: usize,
    pub last_error: Option<String>,
}

/// Serializable mirror of `MailboxStatus` — the runtime enum stays
/// internal ; the snapshot exposes a stable lowercase tag so tooling
/// consumers can match on strings without depending on the runtime
/// crate's debug repr.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MailboxStatusLabel {
    Live,
    Poisoned,
}

impl MailboxStatusLabel {
    pub fn as_str(&self) -> &'static str {
        match self {
            MailboxStatusLabel::Live => "live",
            MailboxStatusLabel::Poisoned => "poisoned",
        }
    }
}

impl From<MailboxStatus> for MailboxStatusLabel {
    fn from(s: MailboxStatus) -> Self {
        match s {
            MailboxStatus::Live => MailboxStatusLabel::Live,
            MailboxStatus::Poisoned => MailboxStatusLabel::Poisoned,
        }
    }
}

impl MailboxSummary {
    /// Build a summary by locking the mailbox briefly. Caller owns the
    /// address tuple ; the lock is released before this returns.
    pub fn capture(addr: &ActorAddress, mailbox: &Mailbox) -> Self {
        MailboxSummary {
            aggregate_type: addr.0.clone(),
            aggregate_id: addr.1.clone(),
            status: mailbox.status().into(),
            queue_depth: mailbox.queue_depth(),
            events_processed: mailbox.events_processed_count(),
            dropped_duplicates: mailbox.dropped_duplicates,
            last_error: mailbox.last_error().map(|s| s.to_string()),
        }
    }

    pub fn is_poisoned(&self) -> bool {
        matches!(self.status, MailboxStatusLabel::Poisoned)
    }

    /// JSON projection for the `--json` flag on the debug CLI.
    /// Stable shape : `{type, id, status, queue_depth, events_processed,
    /// dropped_duplicates, last_error}`. Field order matches the table
    /// view so JSON consumers and human readers see the same axes.
    pub fn to_json(&self) -> serde_json::Value {
        serde_json::json!({
            "type": self.aggregate_type,
            "id": self.aggregate_id,
            "status": self.status.as_str(),
            "queue_depth": self.queue_depth,
            "events_processed": self.events_processed,
            "dropped_duplicates": self.dropped_duplicates,
            "last_error": self.last_error,
        })
    }
}

impl Mailboxes {
    /// Snapshot every registered mailbox into a flat Vec of summaries.
    /// Each mailbox is locked briefly in turn ; the lock order is the
    /// HashMap's iteration order (undefined but stable within a single
    /// snapshot). The CLI sorts the result by (type, id) before
    /// rendering so output is deterministic for fixtures.
    pub fn snapshot(&self) -> Vec<MailboxSummary> {
        let mut rows = Vec::with_capacity(self.active_count());
        for addr in self.addresses() {
            if let Some(mb) = self.mailbox_for(&addr) {
                let guard = mb.lock().expect("mailbox mutex poisoned");
                rows.push(MailboxSummary::capture(&addr, &guard));
            }
        }
        rows
    }

    /// Filter to only poisoned mailboxes — convenience for the
    /// `storehouse mailboxes poisoned` subcommand. Equivalent to
    /// `snapshot().into_iter().filter(MailboxSummary::is_poisoned)`
    /// but spelled out so the call-site reads as the intent.
    pub fn snapshot_poisoned(&self) -> Vec<MailboxSummary> {
        self.snapshot().into_iter().filter(MailboxSummary::is_poisoned).collect()
    }

    /// Snapshot a single mailbox by address. Returns None when the
    /// address has never received a delivery (no mailbox exists yet).
    /// Used by `storehouse mailboxes show <type> <id>`.
    pub fn snapshot_one(&self, addr: &ActorAddress) -> Option<MailboxSummary> {
        let mb = self.mailbox_for(addr)?;
        let guard = mb.lock().expect("mailbox mutex poisoned");
        Some(MailboxSummary::capture(addr, &guard))
    }
}
