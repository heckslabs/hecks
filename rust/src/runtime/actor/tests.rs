//! Actor-model smoke tests — the four contracts each story flips on
//!
//! These are cargo unit tests (run via `cargo test actor::tests`).
//! Each test exercises the public registry surface end-to-end, NOT
//! the mailbox in isolation — the advisor's caution "a Mailbox::push
//! ; Mailbox::drain unit test doesn't prove parallelism" is the
//! reason the tests route through `Mailboxes::deliver` +
//! `drain_all_in_parallel`. Synchronization uses Barrier / Condvar
//! — no sleeps — so the suite stays well under the 1-second hook.
//!
//! Tokio substrate (sprint-14 tokio-mailbox-substrate) : every test
//! that calls `drain_all_in_parallel` runs under
//! `#[tokio::test(flavor = "multi_thread", worker_threads = 2)]` so
//! the blocking `Barrier::wait` in
//! `parallel_across_aggregates_no_block` can make progress on two
//! independent worker threads. `same_aggregate_events_handled_in_order`
//! and `duplicate_event_id_handled_once` exercise the sync
//! `drain_all_blocking` path and stay `#[test]`.
//!
//! Story → contract mapping :
//!   actor-per-aggregate-instance → parallel_across_aggregates_no_block
//!   async-event-delivery-bus     → parallel_across_aggregates_no_block (fire-and-forget)
//!   per-actor-failure-isolation  → panic_in_one_actor_doesnt_block_others
//!   causal-ordering-per-aggregate → same_aggregate_events_handled_in_order
//!   (Idempotency is universal)   → duplicate_event_id_handled_once
//!   (No task leak ; tokio sub.)  → tokio_task_count_matches_active_mailboxes

use super::{Envelope, Mailboxes};
use crate::runtime::event_bus::Event;
use std::collections::HashMap;
use std::sync::{Arc, Barrier, Mutex};

fn mk_event(agg_type: &str, agg_id: &str, evt_name: &str) -> Event {
    Event {
        name: evt_name.to_string(),
        aggregate_type: agg_type.to_string(),
        aggregate_id: agg_id.to_string(),
        data: HashMap::new(),
    }
}

fn env(agg_type: &str, agg_id: &str, evt_name: &str, event_id: &str) -> Envelope {
    Envelope::new(mk_event(agg_type, agg_id, evt_name), event_id)
}

/// CONTRACT : causal-ordering-per-aggregate — two envelopes addressed
/// to the same actor handle in dispatch order. The recorder thread
/// observes the same sequence the deliver calls used.
#[test]
fn same_aggregate_events_handled_in_order() {
    let mut reg = Mailboxes::new();
    let addr = ("Sprint".to_string(), "14".to_string());
    reg.deliver(addr.clone(), env("Sprint", "14", "Planned", "e1"));
    reg.deliver(addr.clone(), env("Sprint", "14", "Activated", "e2"));
    reg.deliver(addr,         env("Sprint", "14", "Closed",    "e3"));

    let order = Arc::new(Mutex::new(Vec::<String>::new()));
    let order_clone = Arc::clone(&order);
    reg.drain_all_blocking(move |env| {
        order_clone.lock().unwrap().push(env.event.name.clone());
    });
    let got = order.lock().unwrap().clone();
    assert_eq!(got, vec!["Planned".to_string(), "Activated".into(), "Closed".into()],
        "causal-ordering-per-aggregate violated : per-mailbox FIFO must preserve dispatch order");
}

/// CONTRACT : actor-per-aggregate-instance + async-event-delivery-bus
/// — a slow handler on actor B cannot block actor A from making
/// progress. Uses a Barrier with size=2 : both handlers must reach
/// the wait point before either can proceed. If A were serialized
/// behind B the barrier would deadlock and `wait` would hang forever
/// — we cap the test with the outer cargo-test timeout.
///
/// Tokio multi-thread flavor required : the blocking `Barrier::wait`
/// inside each spawn_blocking task needs two independent worker
/// threads to make progress.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn parallel_across_aggregates_no_block() {
    let mut reg = Mailboxes::new();
    let addr_a = ("Sprint".to_string(), "A".to_string());
    let addr_b = ("Sprint".to_string(), "B".to_string());
    reg.deliver(addr_a, env("Sprint", "A", "X", "a1"));
    reg.deliver(addr_b, env("Sprint", "B", "Y", "b1"));

    let barrier = Arc::new(Barrier::new(2));
    let barrier_clone = Arc::clone(&barrier);
    // The parallel drain spawns one tokio task per mailbox via
    // JoinSet::spawn_blocking. Each task hits the barrier ; the
    // test passes only when both reach the wait simultaneously —
    // proving cross-actor parallelism. If actor A were blocked
    // behind actor B the barrier would never lift and the test
    // would hang (cargo test enforces an outer timeout).
    let summary = reg.drain_all_in_parallel(move |_env| {
        barrier_clone.wait();
    }).await;
    assert_eq!(summary.handled, 2,
        "actor-per-aggregate-instance : both mailboxes must drain in parallel");
    assert_eq!(summary.mailbox_count, 2);
    let _ = barrier;
}

/// CONTRACT : per-actor-failure-isolation — a panic in actor B's
/// handler does NOT prevent actor A's handler from completing. After
/// the drain the registry reports 1 poisoned, 1 handled. Multi-thread
/// flavor required so both spawn_blocking tasks can run independently.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn panic_in_one_actor_doesnt_block_others() {
    let mut reg = Mailboxes::new();
    let good = ("Sprint".to_string(), "GOOD".to_string());
    let bad  = ("Sprint".to_string(), "BAD".to_string());
    reg.deliver(good, env("Sprint", "GOOD", "X", "g1"));
    reg.deliver(bad,  env("Sprint", "BAD",  "Y", "b1"));

    let summary = reg.drain_all_in_parallel(|env| {
        if env.event.aggregate_id == "BAD" {
            panic!("intentional fault in actor BAD");
        }
    }).await;
    assert_eq!(summary.handled, 1,
        "per-actor-failure-isolation : good actor must complete despite sibling panic");
    assert_eq!(summary.poisoned, 1,
        "per-actor-failure-isolation : bad actor is marked poisoned, not the registry");

    // The bad mailbox's status must be Poisoned with a recorded reason.
    let bad_addr = ("Sprint".to_string(), "BAD".to_string());
    let bad_mb = reg.mailbox_for(&bad_addr).expect("bad mailbox must still be addressable post-poison");
    let guard = bad_mb.lock().unwrap();
    assert_eq!(guard.status, super::MailboxStatus::Poisoned);
    assert!(guard.last_panic.as_ref().map_or(false, |r| r.contains("intentional fault")),
        "poisoned mailbox must record the panic reason for the audit trail");
}

/// CONTRACT : universal idempotency — two envelopes with the same
/// event_id arriving at the same mailbox produce ONE handler
/// invocation. The second push is suppressed at the mailbox
/// boundary, before the handler runs. The dropped_duplicates
/// counter exposes the dedup for the storehouse audit trail.
#[test]
fn duplicate_event_id_handled_once() {
    let mut reg = Mailboxes::new();
    let addr = ("Sprint".to_string(), "14".to_string());
    let accepted_1 = reg.deliver(addr.clone(), env("Sprint", "14", "Planned", "evt-7"));
    let accepted_2 = reg.deliver(addr.clone(), env("Sprint", "14", "Planned", "evt-7"));
    assert!(accepted_1, "first delivery of evt-7 must be accepted");
    assert!(!accepted_2, "duplicate event_id must be rejected at the mailbox boundary");

    let count = Arc::new(Mutex::new(0usize));
    let count_clone = Arc::clone(&count);
    let summary = reg.drain_all_blocking(move |_env| {
        *count_clone.lock().unwrap() += 1;
    });
    assert_eq!(summary.handled, 1, "idempotency : handler runs exactly once for the deduped event_id");
    assert_eq!(*count.lock().unwrap(), 1);

    let mb = reg.mailbox_for(&addr).unwrap();
    let guard = mb.lock().unwrap();
    assert_eq!(guard.dropped_duplicates, 1,
        "audit trail : the dedupe counter must record the suppressed delivery");
}

/// Ancillary : poisoned mailbox still accepts new envelopes (audit
/// trail intact) but the handler is never re-invoked on them.
#[test]
fn poisoned_mailbox_drops_new_envelopes_silently() {
    let mut reg = Mailboxes::new();
    let addr = ("Sprint".to_string(), "14".to_string());
    reg.deliver(addr.clone(), env("Sprint", "14", "X", "p1"));
    // Drain ONCE with a panic so the mailbox flips Poisoned.
    let _ = reg.drain_all_blocking(|_env| panic!("force poison"));
    // Deliver a fresh envelope post-poison ; should enqueue but never run.
    let accepted = reg.deliver(addr.clone(), env("Sprint", "14", "Y", "p2"));
    assert!(accepted, "fresh event_ids still enqueue on a poisoned mailbox (audit)");
    let summary = reg.drain_all_blocking(|_env| {
        panic!("handler must NEVER run on a poisoned mailbox");
    });
    assert_eq!(summary.handled, 0);
    let mb = reg.mailbox_for(&addr).unwrap();
    let guard = mb.lock().unwrap();
    assert_eq!(guard.status, super::MailboxStatus::Poisoned);
}

/// CONTRACT (tokio substrate, sprint-14) : the JoinSet must drain to
/// empty after `drain_all_in_parallel` returns. No task leak. The
/// honest probe is "the summary's mailbox_count equals the number of
/// addresses we delivered to, and a SECOND drain call after that
/// reports zero handled" — proving every spawned task was joined
/// (no orphans wedged in the runtime) and no mailbox is still
/// holding undrained envelopes.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn tokio_task_count_matches_active_mailboxes() {
    let mut reg = Mailboxes::new();
    let addrs: Vec<(String, String)> = (0..5)
        .map(|i| ("Sprint".to_string(), format!("S{}", i)))
        .collect();
    for (i, addr) in addrs.iter().enumerate() {
        reg.deliver(addr.clone(), env("Sprint", &addr.1, "X", &format!("e{}", i)));
    }
    assert_eq!(reg.active_count(), 5,
        "deliver must lazy-create exactly one mailbox per address");

    let summary = reg.drain_all_in_parallel(|_env| ()).await;
    assert_eq!(summary.handled, 5,
        "every spawned task must complete and be joined before drain returns");
    assert_eq!(summary.poisoned, 0);
    assert_eq!(summary.mailbox_count, 5,
        "mailbox_count tracks the count of tasks spawned this drain");

    // A second drain on the same registry sees empty mailboxes —
    // proves no envelope was left unhandled by an orphaned task.
    let again = reg.drain_all_in_parallel(|_env| panic!("must not run")).await;
    assert_eq!(again.handled, 0,
        "no orphaned envelopes ; every queue drained on the first pass");
    assert_eq!(again.poisoned, 0,
        "registry stays clean ; no zombie tasks rerunning handlers");
}
