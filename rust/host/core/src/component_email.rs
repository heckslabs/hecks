// Calls an email adapter compiled to a component (world `email-adapter` in `rust/host/wit`):
// one message in, one delivery out. The component reaches the provider only through the imports
// the caller's `Imports` grants; this file holds the binding and the limits of one delivery.

use crate::component_imports::Imports;
use crate::component_runner::run_with;
use crate::wasm_runner::Limits;
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

mod wit {
    wasmtime::component::bindgen!({
        path: "../wit",
        world: "email-adapter",
        with: {
            "hecks:adapters/clock": crate::component_imports::wit::hecks::adapters::clock,
            "hecks:adapters/secrets": crate::component_imports::wit::hecks::adapters::secrets,
            "hecks:adapters/http-out": crate::component_imports::wit::hecks::adapters::http_out,
        },
    });
}

pub use wit::hecks::adapters::mail::{Delivery, Message, Sender};

/// What one delivery may spend. The deadline counts wall time, host calls included, so it covers
/// the worst a well-behaved adapter does: four requests at their 15 s timeout and three waits at
/// the five-second sleep cap (75 s), with room to spare. Memory and output are an email's worth.
pub const EMAIL_LIMITS: Limits = Limits {
    deadline: Duration::from_secs(90),
    memory_bytes: 64 * 1024 * 1024,
    output_bytes: 64 * 1024,
};

/// Hands `message` to the email component at `path`, sent as `sender`, with `imports` answering
/// what the component asks of the host. An `Err` is the run's own failure (no such component, a
/// trap, a passed cap); a provider's refusal is a `Delivery` with `ok: false`.
pub fn deliver(
    path: &Path,
    imports: Arc<dyn Imports>,
    sender: &Sender,
    message: &Message,
) -> anyhow::Result<Delivery> {
    run_with(EMAIL_LIMITS, path, imports, |store, instance| {
        let adapter = wit::EmailAdapter::new(&mut *store, instance)?;
        Ok(adapter.call_deliver(&mut *store, sender, message)?)
    })
}
