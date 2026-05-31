//! MailboxRegistry — `HashMap<(type, id), Mailbox>` keyed by address
//!
//! The address `(aggregate_type, aggregate_id)` IS the actor — there
//! is no separate registry of "which actors exist." When the bus has
//! an envelope addressed to `(Sprint, 14)` the registry's `deliver`
//! call lazily creates the mailbox if missing then enqueues the
//! envelope. Subsequent envelopes for the same address reuse the
//! existing mailbox so causal ordering holds.
//!
//! Parallelism : `drain_all_in_parallel` spawns one OS thread per
//! non-empty mailbox and joins them. Different mailboxes process in
//! parallel (parallelism across aggregate instances) ; one mailbox's
//! envelopes process sequentially (causal per-aggregate). Per-actor
//! failure isolation lives in `supervisor.rs` — wrapped around the
//! handler invocation inside each spawned thread.
//!
//! Why std::thread rather than tokio : the rest of the runtime is
//! synchronous (sync dispatch contract per sprint-12 architecture
//! decision). std::thread keeps the actor model layered ON TOP of
//! sync without forcing #[tokio::main] through every entry point.
//! Tokio integration is a separate sprint-14 follow-up card.
//!
//! Usage :
//!   let mut reg = MailboxRegistry::new();
//!   reg.deliver(("Sprint".into(), "14".into()), envelope);
//!   reg.drain_all_in_parallel(handler);

use super::{Envelope, Mailbox, MailboxStatus, supervisor};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::thread;

/// `(aggregate_type, aggregate_id)` — the actor's address. The type
/// is the Pascal-case aggregate name ("Sprint") ; the id is the
/// instance id ("14"). Together they uniquely identify a mailbox.
pub type ActorAddress = (String, String);

/// One mailbox per actor address. The Mutex<Mailbox> wrapper lets
/// the parallel drain take exclusive access to each mailbox for the
/// duration of its handler invocation while leaving sibling mailboxes
/// freely accessible. The outer HashMap is held by &mut so deliver
/// + drain are serialized at the registry boundary — concurrent
/// `deliver` calls from external threads would need a different
/// shape (separate enqueue ports per mailbox) but the sync-runtime
/// caller doesn't have that need.
pub struct MailboxRegistry {
    mailboxes: HashMap<ActorAddress, Arc<Mutex<Mailbox>>>,
}

impl MailboxRegistry {
    pub fn new() -> Self { MailboxRegistry { mailboxes: HashMap::new() } }

    /// Enqueue `env` into the mailbox at `addr`, creating the mailbox
    /// lazily on first delivery. Returns `true` when the envelope was
    /// freshly accepted, `false` when the event_id was already seen
    /// (idempotency dedup at the mailbox boundary).
    pub fn deliver(&mut self, addr: ActorAddress, env: Envelope) -> bool {
        let mb = self.mailboxes.entry(addr)
            .or_insert_with(|| Arc::new(Mutex::new(Mailbox::new())));
        let mut guard = mb.lock().expect("mailbox mutex poisoned");
        guard.push(env)
    }

    /// Drain every non-empty mailbox in parallel. One OS thread per
    /// active mailbox ; handler is called once per envelope inside
    /// `supervisor::guarded_invoke` so panics are caught and the
    /// affected mailbox is marked Poisoned without unwinding the
    /// registry. Returns when every spawned thread joins.
    ///
    /// The handler must be `Send + Sync + 'static` so it can cross
    /// the thread boundary. The runtime's actual cascade handler is
    /// not Send (it borrows &mut Runtime) ; the registry-level smoke
    /// proof uses a pure closure. Production wiring will route
    /// through a message-passing shim in event_bus.rs (separate card).
    pub fn drain_all_in_parallel<F>(&mut self, handler: F) -> DrainSummary
    where F: Fn(&Envelope) + Send + Sync + 'static
    {
        let handler = Arc::new(handler);
        let mut joins = Vec::with_capacity(self.mailboxes.len());
        let mut addrs = Vec::with_capacity(self.mailboxes.len());
        for (addr, mb) in &self.mailboxes {
            let mb_clone = Arc::clone(mb);
            let h_clone = Arc::clone(&handler);
            let addr_clone = addr.clone();
            addrs.push(addr.clone());
            joins.push(thread::spawn(move || {
                drain_one(&addr_clone, mb_clone, h_clone)
            }));
        }
        let mut handled = 0usize;
        let mut poisoned = 0usize;
        for j in joins {
            let outcome = j.join().unwrap_or(supervisor::SupervisorOutcome::Poisoned("join failed".into()));
            match outcome {
                supervisor::SupervisorOutcome::Drained(n) => handled += n,
                supervisor::SupervisorOutcome::Poisoned(_) => poisoned += 1,
            }
        }
        DrainSummary { handled, poisoned, mailbox_count: addrs.len() }
    }

    /// Synchronous drain — used by tests that need deterministic
    /// ordering. Drains each mailbox in turn on the calling thread.
    /// Same supervisor wrapping, no parallelism.
    pub fn drain_all_blocking<F: FnMut(&Envelope)>(&mut self, mut handler: F) -> DrainSummary {
        let mut handled = 0usize;
        let mut poisoned = 0usize;
        for (_addr, mb) in self.mailboxes.iter_mut() {
            let mut guard = mb.lock().expect("mailbox mutex poisoned");
            while let Some(env) = guard.pop() {
                if guard.status == MailboxStatus::Poisoned { continue; }
                let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| handler(&env)));
                if let Err(p) = result {
                    let reason = supervisor::stringify_panic(&p);
                    guard.mark_poisoned(reason);
                    poisoned += 1;
                } else {
                    handled += 1;
                    guard.note_handled();
                }
            }
        }
        DrainSummary { handled, poisoned, mailbox_count: self.mailboxes.len() }
    }

    pub fn mailbox_for(&self, addr: &ActorAddress) -> Option<Arc<Mutex<Mailbox>>> {
        self.mailboxes.get(addr).cloned()
    }

    pub fn active_count(&self) -> usize { self.mailboxes.len() }

    pub fn addresses(&self) -> Vec<ActorAddress> {
        self.mailboxes.keys().cloned().collect()
    }
}

impl Default for MailboxRegistry { fn default() -> Self { Self::new() } }

#[derive(Debug, Clone, Copy)]
pub struct DrainSummary {
    pub handled: usize,
    pub poisoned: usize,
    pub mailbox_count: usize,
}

/// Drain helper run inside each spawned thread. Pops envelopes one
/// at a time and invokes the handler under `catch_unwind` so a panic
/// in one envelope-handler does not propagate up through the join.
fn drain_one<F>(_addr: &ActorAddress, mb: Arc<Mutex<Mailbox>>, handler: Arc<F>) -> supervisor::SupervisorOutcome
where F: Fn(&Envelope) + Send + Sync + 'static
{
    let mut handled = 0usize;
    loop {
        let env = {
            let mut guard = mb.lock().expect("mailbox mutex poisoned");
            if guard.status == MailboxStatus::Poisoned { return supervisor::SupervisorOutcome::Poisoned("already poisoned".into()); }
            match guard.pop() { Some(e) => e, None => return supervisor::SupervisorOutcome::Drained(handled) }
        };
        let h = Arc::clone(&handler);
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| h(&env)));
        match result {
            Ok(()) => {
                handled += 1;
                let mut guard = mb.lock().expect("mailbox mutex poisoned");
                guard.note_handled();
            }
            Err(p) => {
                let reason = supervisor::stringify_panic(&p);
                let mut guard = mb.lock().expect("mailbox mutex poisoned");
                guard.mark_poisoned(reason.clone());
                return supervisor::SupervisorOutcome::Poisoned(reason);
            }
        }
    }
}
