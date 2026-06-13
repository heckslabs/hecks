//! The bus — the synchronous boundary, and the only caller of ports.
//!
//! [antibody-exempt: rust/examples/order_boundary/bus.rs — handwritten
//!  reference pattern for the code generator (sync-domain / async-adapter
//!  boundary, decided with Chris 2026-06-12). Retires when the specializer
//!  emits this projection.]
//!
//! One synchronous pipeline, the distilled shape of the runtime's
//! command_dispatch : resolve mint-vs-load by the utterance's node
//! KIND (factory → mint, command → load), run the pure decide, persist
//! through the reply port, publish through the effect port. Every line
//! is a plain blocking call ; the async world is invisible from here.
//!
//! The bus runs on the host's sync thread (see main.rs) — NEVER inside
//! the executor. That single placement rule is what makes the reply
//! ports' blocking safe.

use crate::domain::{self, DomainError, Event, Utterance};
use crate::ports::{EffectPort, PortError, StorePort};

pub struct Bus {
    store: StorePort,
    effects: EffectPort,
    /// The event log — the bus's own durable record of what happened.
    pub log: Vec<Event>,
}

#[derive(Debug)]
pub enum BusError {
    Domain(DomainError),
    Port(PortError),
    /// Factory verb on an existing ref — a birth never upserts
    /// (mirrors RuntimeError::AggregateAlreadyExists).
    AlreadyExists(String),
    /// Command verb on an absent ref — a transition never mints.
    NotFound(String),
}

impl std::fmt::Display for BusError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            BusError::Domain(e) => write!(f, "domain refused: {:?}", e),
            BusError::Port(e) => write!(f, "port failed: {}", e),
            BusError::AlreadyExists(r) => write!(f, "already exists: '{}' — a birth never upserts", r),
            BusError::NotFound(r) => write!(f, "not found: '{}' — a transition never mints", r),
        }
    }
}

impl Bus {
    pub fn new(store: StorePort, effects: EffectPort) -> Self {
        Bus { store, effects, log: Vec::new() }
    }

    /// The two-path dispatch, synchronous end to end.
    pub fn dispatch(&mut self, utterance: Utterance) -> Result<Event, BusError> {
        let r#ref = domain::target_ref(&utterance).to_string();

        // 1. Mint vs load — decided by the node KIND, never by a name.
        let current = self.store.find(&r#ref).map_err(BusError::Port)?;
        let current = if domain::is_factory(&utterance) {
            if current.is_some() {
                return Err(BusError::AlreadyExists(r#ref));
            }
            None
        } else {
            match current {
                Some(order) => Some(order),
                None => return Err(BusError::NotFound(r#ref)),
            }
        };

        // 2. The pure decide — the only domain call, fully synchronous.
        let (next, event) = domain::decide(current.as_ref(), &utterance).map_err(BusError::Domain)?;

        // 3. Persist through the reply port (async worker underneath ;
        //    this line cannot tell).
        self.store.save(next).map_err(BusError::Port)?;

        // 4. Record + publish. The effect port fans the event to
        //    whatever the hecksagon bound — the domain composed the
        //    effect, the adapter runs it.
        self.log.push(event.clone());
        self.effects.publish(&event);
        Ok(event)
    }
}
