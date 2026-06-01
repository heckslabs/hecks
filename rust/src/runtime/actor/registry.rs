//! Mailboxes — `HashMap<(type, id), Mailbox>` keyed by address
//!
//! The address `(aggregate_type, aggregate_id)` IS the actor — there
//! is no separate registry of "which actors exist." The HashMap IS
//! the lookup table. When the bus has an envelope addressed to
//! `(Sprint, 14)` the wrapper's `deliver` call lazily creates the
//! mailbox if missing then enqueues the envelope. Subsequent
//! envelopes for the same address reuse the existing mailbox so
//! causal ordering holds.
//!
//! Parallelism : `drain_all_in_parallel` spawns one tokio task per
//! non-empty mailbox into a `JoinSet` and awaits them. Different
//! mailboxes process in parallel (parallelism across aggregate
//! instances) on the tokio worker thread pool ; one mailbox's
//! envelopes process sequentially (causal per-aggregate). Per-actor
//! failure isolation lives in the JoinSet drain loop — a panicked
//! task surfaces as `JoinError::is_panic()` and is translated into
//! a `Poisoned` supervisor outcome without unwinding the registry.
//!
//! Why tokio rather than std::thread (sprint-14 tokio-mailbox-substrate) :
//! the previous substrate spawned one OS thread per active mailbox.
//! That works for the four smoke tests but does not scale — every
//! cascade fan-out costs N thread creations. tokio tasks are
//! lightweight, the runtime pool is reused, and the mailbox
//! abstraction is unchanged (drain_all_in_parallel still takes a
//! handler and returns a DrainSummary). The mailbox's internal
//! Mutex stays `std::sync::Mutex` because no `.await` is held across
//! the lock — tokio's own guidance endorses std::sync::Mutex for
//! short synchronous critical sections.
//!
//! Usage :
//!   let mut reg = MailboxRegistry::new();
//!   reg.deliver(("Sprint".into(), "14".into()), envelope);
//!   reg.drain_all_in_parallel(handler).await;
//!   let mut mailboxes = Mailboxes::new();
//!   mailboxes.deliver(("Sprint".into(), "14".into()), envelope);
//!   mailboxes.drain_all_in_parallel(handler);

use super::{Envelope, Mailbox, MailboxStatus, supervisor};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use tokio::task::JoinSet;

/// `(aggregate_type, aggregate_id)` — the actor's address. The type
/// is the Pascal-case aggregate name ("Sprint") ; the id is the
/// instance id ("14"). Together they uniquely identify a mailbox.
pub type ActorAddress = (String, String);

/// One mailbox per actor address. The Mutex<Mailbox> wrapper lets
/// the parallel drain take exclusive access to each mailbox for the
/// duration of its handler invocation while leaving sibling mailboxes
/// freely accessible. The outer HashMap is held by &mut so deliver
/// + drain are serialized at the Mailboxes boundary — concurrent
/// `deliver` calls from external threads would need a different
/// shape (separate enqueue ports per mailbox) but the sync-runtime
/// caller doesn't have that need.
///
/// `std::sync::Mutex` (NOT `tokio::sync::Mutex`) — the lock is held
/// only across the brief synchronous critical section that pops one
/// envelope or appends to a counter ; no `.await` is held across the
/// lock so a sync mutex is correct AND faster.
pub struct MailboxRegistry {
pub struct Mailboxes {
    mailboxes: HashMap<ActorAddress, Arc<Mutex<Mailbox>>>,
}

impl Mailboxes {
    pub fn new() -> Self { Mailboxes { mailboxes: HashMap::new() } }

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

    /// Drain every non-empty mailbox in parallel. One tokio task per
    /// active mailbox spawned into a `JoinSet` ; handler is called
    /// once per envelope. Panics surface as `JoinError::is_panic()`
    /// and are translated into `SupervisorOutcome::Poisoned` so the
    /// affected mailbox is marked Poisoned without unwinding the
    /// registry. Returns when every spawned task has been joined.
    /// Mailboxes table. Returns when every spawned thread joins.
    ///
    /// The handler must be `Send + Sync + 'static` so it can cross
    /// the task boundary. The runtime's actual cascade handler is
    /// not Send (it borrows &mut Runtime) ; the registry-level smoke
    /// the thread boundary. The runtime's actual cascade handler is
    /// not Send (it borrows &mut Runtime) ; the Mailboxes-level smoke
    /// proof uses a pure closure. Production wiring will route
    /// through a message-passing shim in event_bus.rs (separate card).
    ///
    /// Async : must be `.await`-ed from a tokio runtime context. The
    /// 4 actor::tests use `#[tokio::test(flavor = "multi_thread")]`
    /// because the `parallel_across_aggregates_no_block` test uses a
    /// blocking `Barrier::wait` inside the handler — that needs ≥2
    /// worker threads to make progress.
    pub async fn drain_all_in_parallel<F>(&mut self, handler: F) -> DrainSummary
    where F: Fn(&Envelope) + Send + Sync + 'static
    {
        let handler = Arc::new(handler);
        let mut joins: JoinSet<supervisor::SupervisorOutcome> = JoinSet::new();
        let mailbox_count = self.mailboxes.len();
        for (addr, mb) in &self.mailboxes {
            let mb_clone = Arc::clone(mb);
            let h_clone = Arc::clone(&handler);
            let addr_clone = addr.clone();
            joins.spawn_blocking(move || {
                drain_one(&addr_clone, mb_clone, h_clone)
            });
        }
        let mut handled = 0usize;
        let mut poisoned = 0usize;
        while let Some(joined) = joins.join_next().await {
            match joined {
                Ok(supervisor::SupervisorOutcome::Drained(n)) => handled += n,
                Ok(supervisor::SupervisorOutcome::Poisoned(_)) => poisoned += 1,
                Err(join_err) => {
                    // A panic that escapes the inner catch_unwind is
                    // turned into a Poisoned outcome here. drain_one
                    // already catches handler panics internally ; this
                    // path covers join-level cancellation or an
                    // unexpected runtime error. `_reason` exists for
                    // future audit-trail wiring but is not yet
                    // surfaced through DrainSummary.
                    let _reason = if join_err.is_panic() {
                        supervisor::stringify_panic(&join_err.into_panic())
                    } else {
                        "join failed".to_string()
                    };
                    poisoned += 1;
                }
            }
        }
        DrainSummary { handled, poisoned, mailbox_count }
    }

    /// Synchronous drain — used by tests that need deterministic
    /// ordering AND a non-async API surface. Drains each mailbox in
    /// turn on the calling thread. Same supervisor wrapping, no
    /// parallelism. Does NOT touch tokio so it remains callable
    /// from any synchronous context (e.g. the existing sync command
    /// dispatch path).
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

impl Default for Mailboxes { fn default() -> Self { Self::new() } }

#[derive(Debug, Clone, Copy)]
pub struct DrainSummary {
    pub handled: usize,
    pub poisoned: usize,
    pub mailbox_count: usize,
}

/// Drain helper run inside each spawned tokio task. Pops envelopes
/// one at a time and invokes the handler under `catch_unwind` so a
/// panic in one envelope-handler does not propagate up through the
/// JoinSet — instead, it returns a `Poisoned` outcome and the
/// mailbox's status is flipped to Poisoned.
///
/// Runs under `JoinSet::spawn_blocking` because the handler is a
/// synchronous closure that may block (the actor tests use
/// `std::sync::Barrier::wait`). spawn_blocking moves the work onto
/// tokio's blocking-task pool so the async worker threads are not
/// starved. From the registry's point of view the spawn target is
/// fungible — the task abstraction is what matters.
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
