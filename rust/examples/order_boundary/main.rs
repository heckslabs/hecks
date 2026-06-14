//! Order boundary — the reference host. Run :
//!
//!     cargo run --release --example order_boundary
//!
//! [antibody-exempt: rust/examples/order_boundary/main.rs — handwritten
//!  reference pattern for the code generator (sync-domain / async-adapter
//!  boundary, decided with Chris 2026-06-12). Retires when the specializer
//!  emits this projection.]
//!
//! THE PLACEMENT RULE, enacted : the tokio runtime exists only inside
//! `main`, adapters are spawned onto it, and the bus loop runs on the
//! plain main thread. Above the boundary : no executor, no lock, no
//! channel — domain.rs and bus.rs compile without knowing tokio
//! exists (only ports.rs names it, once, at the bridge).
//!
//! What you'll see : Place mints (pending) → the payment worker fails
//! twice and backs off (adapter noise on stderr) → the verdict
//! re-enters as Authorize → the order is authorized. The domain ran
//! synchronously start to finish ; a second Place on the same ref is
//! refused (births never upsert) ; Cancel after authorization is
//! refused by the lifecycle. The event log tells the whole story.

mod adapters;
mod bus;
mod domain;
mod ports;

use domain::Utterance;
use ports::CommandSink;
use tokio::sync::mpsc;

fn main() {
    // The ONLY executor in the program — owned by the host edge.
    let runtime = tokio::runtime::Runtime::new().expect("tokio runtime");
    let handle = runtime.handle();

    // The command queue — how async outcomes re-enter the sync world.
    let (cmd_tx, mut cmd_rx) = mpsc::channel::<Utterance>(64);
    let sink = CommandSink { tx: cmd_tx.clone() };

    // Adapters : async store (the R2/sqlite shape) by default ; set
    // HECKS_STORE=memory to swap in the plain-thread sync adapter —
    // nothing above this line notices, which is the entire claim.
    let store = match std::env::var("HECKS_STORE").as_deref() {
        Ok("memory") => adapters::store_memory::spawn(),
        _ => adapters::store_async::spawn(handle),
    };
    let effects = adapters::payment::spawn(handle, sink);

    // The bus lives on THIS plain thread — never inside the executor.
    let mut bus = bus::Bus::new(store, effects);

    // ── Act 1 : the customer places an order (a factory verb mints).
    let placed = bus.dispatch(Utterance::Place {
        r#ref: "ord-1".into(),
        customer_name: "Chris".into(),
        amount_cents: 4200,
    });
    println!("place → {:?}", placed.as_ref().map(|e| e.name));

    // ── Act 2 : a birth never upserts.
    let again = bus.dispatch(Utterance::Place {
        r#ref: "ord-1".into(),
        customer_name: "Chris".into(),
        amount_cents: 4200,
    });
    if let Err(refusal) = &again {
        println!("place again → {}", refusal);
    }

    // ── Act 3 : drain the command queue until the async verdict
    //    arrives. blocking_recv on the plain thread — the sync world
    //    waits on DOMAIN LANGUAGE (an utterance), never on a future.
    while let Some(utterance) = cmd_rx.blocking_recv() {
        let result = bus.dispatch(utterance);
        println!("re-entry → {:?}", result.as_ref().map(|e| e.name));
        if matches!(result, Ok(ref e) if e.name == "OrderAuthorized" || e.name == "OrderDeclined") {
            break; // verdict landed — the demo's work is done
        }
    }

    // ── Act 4 : the lifecycle still guards — cancelling an authorized
    //    order is refused, synchronously, by pure domain code.
    let cancel = bus.dispatch(Utterance::Cancel { r#ref: "ord-1".into() });
    if let Err(refusal) = &cancel {
        println!("cancel after verdict → {}", refusal);
    }

    println!("\nevent log :");
    for event in &bus.log {
        println!("  {} — {}", event.order_ref, event.name);
    }
}
