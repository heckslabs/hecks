//! Store adapter — a SYNCHRONOUS implementation of the same port.
//!
//! [antibody-exempt: rust/examples/order_boundary/adapters/store_memory.rs
//!  — handwritten reference pattern for the code generator (sync-domain /
//!  async-adapter boundary, decided with Chris 2026-06-12). Retires when
//!  the specializer emits this projection.]
//!
//! Proof that the port imposes NO async on its implementations : this
//! adapter services the same StoreRequest channel from a plain OS
//! thread, no executor at all. Tests use this one ; the bus cannot
//! tell the difference — which is the entire claim of the pattern.

use crate::domain::Order;
use crate::ports::{StorePort, StoreRequest};
use std::collections::HashMap;
use tokio::sync::mpsc;

pub fn spawn() -> StorePort {
    let (tx, mut rx) = mpsc::channel::<StoreRequest>(64);
    std::thread::spawn(move || {
        let mut records: HashMap<String, Order> = HashMap::new();
        while let Some(request) = rx.blocking_recv() {
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
