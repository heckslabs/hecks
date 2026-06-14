//! The adapter layer — EVERYTHING asynchronous lives below this line.
//!
//! [antibody-exempt: rust/examples/order_boundary/adapters/mod.rs —
//!  handwritten reference pattern for the code generator (sync-domain /
//!  async-adapter boundary, decided with Chris 2026-06-12). Retires when
//!  the specializer emits this projection from order.hecksagon.]
//!
//! tokio, channels, sleeps, retries, backoff, flaky remotes : all of it
//! is HERE and only here. Each worker owns its mess ; the sync world
//! above sees a StorePort, an EffectPort, and utterances arriving in
//! the command queue. Nothing else crosses.

pub mod payment;
pub mod store_async;
pub mod store_memory;
