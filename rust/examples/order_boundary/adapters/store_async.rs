//! Store adapter — the REPLY port worker (the heki_r2 / sqlite shape).
//!
//! [antibody-exempt: rust/examples/order_boundary/adapters/store_async.rs
//!  — handwritten reference pattern for the code generator (sync-domain /
//!  async-adapter boundary, decided with Chris 2026-06-12). Retires when
//!  the specializer emits this projection.]
//!
//! An async task owns the data and services StoreRequest messages.
//! The simulated 2ms latency stands in for R2 / sqlite / network IO —
//! the exact place heki_r2's `async fn read_record / upsert_record`
//! belong, instead of exporting async signatures upward. If the real
//! backend needs retries, THEY GO HERE, inside the worker loop ; the
//! sync facade's contract (answer or timeout) does not change.

use crate::domain::Order;
use crate::ports::{StorePort, StoreRequest};
use std::collections::HashMap;
use std::time::Duration;
use tokio::sync::mpsc;

/// Spawn the worker onto the host executor ; hand back the sync facade.
/// The facade is the only thing that escapes — the task, the map, the
/// channel receiver all stay private to this function.
pub fn spawn(handle: &tokio::runtime::Handle) -> StorePort {
    let (tx, mut rx) = mpsc::channel::<StoreRequest>(64);
    handle.spawn(async move {
        let mut records: HashMap<String, Order> = HashMap::new();
        while let Some(request) = rx.recv().await {
            // Stand-in for real backend latency (R2 round-trip, sqlite
            // write, …). Retries/backoff for a flaky backend would
            // wrap THIS await — never the caller.
            tokio::time::sleep(Duration::from_millis(2)).await;
            match request {
                StoreRequest::Find { r#ref, reply } => {
                    let _ = reply.send(records.get(&r#ref).cloned());
                }
                StoreRequest::Save { order, reply } => {
                    records.insert(order.r#ref.clone(), order);
                    let _ = reply.send(());
                }
            }
        }
    });
    StorePort { tx }
}
