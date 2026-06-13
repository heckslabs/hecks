//! The ports — where synchronous meets asynchronous, and the ONLY
//! place that knows both worlds exist.
//!
//! [antibody-exempt: rust/examples/order_boundary/ports.rs — handwritten
//!  reference pattern for the code generator (sync-domain / async-adapter
//!  boundary, decided with Chris 2026-06-12). Retires when the specializer
//!  emits this projection from order.hecksagon.]
//!
//! Two port shapes, generated from the hecksagon's two adapter kinds :
//!
//!   REPLY port (`StorePort`) — the caller needs an answer NOW. The
//!   sync facade sends a request over an mpsc channel and BLOCKS on a
//!   oneshot reply, bounded by a timeout. The async worker on the
//!   other side does the actual IO (and its retries). The facade's
//!   methods are plain `fn` — the bus never knows an executor exists.
//!
//!   EFFECT port (`EffectPort`) — fire-and-forget. The bus hands the
//!   domain event across ; the worker acts on it asynchronously and
//!   the OUTCOME re-enters the system as a new Utterance through the
//!   CommandSink — never as a return value into domain code.
//!
//! THE DEADLOCK RULE : a reply port's sync facade must only ever be
//! called from OUTSIDE the async executor (the bus thread). Workers
//! never call facades. This is why `blocking_send` / `blocking_recv`
//! are safe here — and why the generator must never emit a facade
//! call inside a worker.

use crate::domain::{Event, Order, Utterance};
use std::time::Duration;
use tokio::sync::{mpsc, oneshot};

/// How long a reply port will wait before declaring the adapter dead.
/// Generated from the hecksagon's `timeout_ms` option.
pub const REPLY_TIMEOUT: Duration = Duration::from_millis(3000);

// ---------------------------------------------------------------
// REPLY port — the store
// ---------------------------------------------------------------

/// Requests the store worker services. Each carries its own oneshot
/// reply slot — the channel is the call stack across the boundary.
pub enum StoreRequest {
    Find { r#ref: String, reply: oneshot::Sender<Option<Order>> },
    Save { order: Order, reply: oneshot::Sender<()> },
}

/// The sync facade the bus holds. Plain `fn` methods — this is the
/// whole point : the signature is synchronous, the implementation
/// behind the channel is not, and nobody above this line can tell.
#[derive(Clone)]
pub struct StorePort {
    pub tx: mpsc::Sender<StoreRequest>,
}

#[derive(Debug)]
pub enum PortError {
    /// The adapter worker is gone or didn't answer inside the timeout.
    AdapterUnavailable(&'static str),
}

impl std::fmt::Display for PortError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            PortError::AdapterUnavailable(which) => write!(f, "adapter unavailable: {}", which),
        }
    }
}

impl StorePort {
    pub fn find(&self, r#ref: &str) -> Result<Option<Order>, PortError> {
        let (reply, rx) = oneshot::channel();
        self.tx
            .blocking_send(StoreRequest::Find { r#ref: r#ref.to_string(), reply })
            .map_err(|_| PortError::AdapterUnavailable("store"))?;
        block_on_reply(rx, "store.find")
    }

    pub fn save(&self, order: Order) -> Result<(), PortError> {
        let (reply, rx) = oneshot::channel();
        self.tx
            .blocking_send(StoreRequest::Save { order, reply })
            .map_err(|_| PortError::AdapterUnavailable("store"))?;
        block_on_reply(rx, "store.save")
    }
}

/// Block the SYNC side on the worker's oneshot answer, bounded.
/// The single bridging primitive every generated reply port shares.
fn block_on_reply<T: Send + 'static>(rx: oneshot::Receiver<T>, what: &'static str) -> Result<T, PortError> {
    // `blocking_recv` parks this (non-executor) thread ; the timeout
    // turns a dead adapter into a loud, attributable error instead of
    // a hang. Tokio's oneshot has no native blocking timeout, so the
    // recv runs on a watchdog thread parked alongside.
    let (done_tx, done_rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let _ = done_tx.send(rx.blocking_recv());
    });
    match done_rx.recv_timeout(REPLY_TIMEOUT) {
        Ok(Ok(value)) => Ok(value),
        _ => Err(PortError::AdapterUnavailable(what)),
    }
}

// ---------------------------------------------------------------
// EFFECT port — the payment gateway (and any event listener)
// ---------------------------------------------------------------

/// The sync facade for fire-and-forget effects. The bus publishes the
/// domain event ; delivery is the adapter's problem from here on.
#[derive(Clone)]
pub struct EffectPort {
    pub tx: mpsc::Sender<Event>,
}

impl EffectPort {
    pub fn publish(&self, event: &Event) {
        // A full effect queue or a dead worker must not fail the
        // already-committed domain transition — the event is durable in
        // the bus log ; delivery is at-least-once from there in the
        // real runtime. Here : best-effort send, loud on the console.
        if self.tx.blocking_send(event.clone()).is_err() {
            eprintln!("[effect-port] worker gone — {} undelivered", event.name);
        }
    }
}

// ---------------------------------------------------------------
// The way BACK in — async outcomes re-enter as utterances
// ---------------------------------------------------------------

/// Handed to every effect worker : its only way to influence the
/// domain. The verdict of an async operation becomes a plain command
/// in the bus queue — the result_into shape. No worker ever holds the
/// bus, a repository, or domain state.
#[derive(Clone)]
pub struct CommandSink {
    pub tx: mpsc::Sender<Utterance>,
}

impl CommandSink {
    pub async fn submit(&self, utterance: Utterance) {
        let _ = self.tx.send(utterance).await;
    }
}
