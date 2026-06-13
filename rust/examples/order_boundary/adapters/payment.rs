//! Payment gateway adapter — the EFFECT port worker. The ugly one,
//! on purpose : retries, exponential backoff, timeouts, a flaky
//! remote — all of it HERE, none of it visible above the boundary.
//!
//! [antibody-exempt: rust/examples/order_boundary/adapters/payment.rs —
//!  handwritten reference pattern for the code generator (sync-domain /
//!  async-adapter boundary, decided with Chris 2026-06-12). Retires when
//!  the specializer emits this projection from order.hecksagon.]
//!
//! Subscribes to the bus's event stream (the hecksagon bound it to
//! OrderPlaced). For each placement it charges the remote ; the remote
//! fails twice before succeeding, the worker retries with exponential
//! backoff (50ms, 100ms, 200ms — the hecksagon's retries/backoff
//! options) — and the DOMAIN NEVER KNOWS. The verdict re-enters as a
//! plain Utterance through the CommandSink : Authorize or Decline,
//! the result_into shape. The branch on the verdict is edge logic.

use crate::domain::{Event, Utterance};
use crate::ports::{CommandSink, EffectPort};
use std::time::Duration;
use tokio::sync::mpsc;

const RETRIES: u32 = 3;
const BASE_BACKOFF: Duration = Duration::from_millis(50);

pub fn spawn(handle: &tokio::runtime::Handle, sink: CommandSink) -> EffectPort {
    let (tx, mut rx) = mpsc::channel::<Event>(64);
    handle.spawn(async move {
        while let Some(event) = rx.recv().await {
            if event.name != "OrderPlaced" {
                continue; // bound to OrderPlaced only (hecksagon trigger_on)
            }
            let sink = sink.clone();
            // One task per charge — a slow gateway never blocks the
            // event stream. Concurrency is an adapter decision too.
            tokio::spawn(charge(event.order_ref.clone(), sink));
        }
    });
    EffectPort { tx }
}

/// Drive one charge to a verdict, retrying the flaky remote. Every
/// await in this file is invisible above the boundary.
async fn charge(order_ref: String, sink: CommandSink) {
    let mut backoff = BASE_BACKOFF;
    for attempt in 1..=RETRIES {
        match flaky_remote_charge(&order_ref, attempt).await {
            Ok(verdict) => {
                let payment_ref = format!("pay_{}_{}", order_ref, attempt);
                eprintln!("[payment] {} verdict on attempt {} — {}", order_ref, attempt, verdict);
                let utterance = if verdict == "approved" {
                    Utterance::Authorize { r#ref: order_ref, payment_ref }
                } else {
                    Utterance::Decline { r#ref: order_ref, payment_ref }
                };
                sink.submit(utterance).await;
                return;
            }
            Err(why) => {
                eprintln!("[payment] {} attempt {} failed ({why}) — backing off {:?}", order_ref, attempt, backoff);
                tokio::time::sleep(backoff).await;
                backoff *= 2;
            }
        }
    }
    // Out of retries — the failure ALSO re-enters as domain language,
    // not as an exception : a decline with a dead-letter payment ref.
    eprintln!("[payment] {} — gateway unreachable after {} attempts, declining", order_ref, RETRIES);
    sink.submit(Utterance::Decline {
        r#ref: order_ref.clone(),
        payment_ref: format!("pay_{}_unreachable", order_ref),
    })
    .await;
}

/// The simulated remote : transient failures on the first two
/// attempts, then a verdict. Stand-in for an HTTP client + gateway.
async fn flaky_remote_charge(_order_ref: &str, attempt: u32) -> Result<&'static str, &'static str> {
    tokio::time::sleep(Duration::from_millis(10)).await; // network
    if attempt < 3 {
        return Err("transient 503");
    }
    Ok("approved")
}
