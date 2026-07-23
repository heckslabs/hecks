//! EventBus — in-process pub/sub
//!
//! Commands emit events. Policies and subscribers listen.
//! Global listeners see everything; named listeners filter by event name.
//!
//! Sprint 14 (`wire-mailbox-registry-into-event-bus`) — `publish` IS the
//! canonical entry point into the actor model. For `delivery :sync`
//! aggregates the dispatcher calls `event_bus.publish(event)` inline
//! (the historical path). For `delivery :actor` aggregates the
//! dispatcher calls `Runtime::enqueue_and_drain(event)`, which
//! enqueues the envelope into the per-aggregate mailbox in the
//! `Mailboxes` and synchronously drains that mailbox into THIS
//! `publish` method — so every subscriber sees every event the same
//! way regardless of delivery mode. The actor side gains causal-
//! ordering-per-aggregate (mailbox FIFO) and idempotency-by-event-id
//! (mailbox seen-set) ; subscribers stay oblivious to the routing.
//!
//! Usage:
//!   let mut bus = EventBus::new();
//!   bus.subscribe("PizzaCreated", |e| println!("{}", e.name));
//!   bus.publish(event);
//!
//! [antibody-exempt: rust/src/runtime/event_bus.rs (causation exposure) —
//!  served-UI + causation plumbing, authorized by Chris 2026-07-03]

use super::Value;
use std::collections::HashMap;

#[derive(Debug, Clone, Default)]
pub struct Event {
    pub name: String,
    pub aggregate_type: String,
    pub aggregate_id: String,
    pub data: HashMap<String, Value>,
    /// The EMITTER's stamped folder address (realm/context) — carried so a
    /// `driven on` binding can enforce realm + context the same way the command
    /// resolver does (slice 3), making event routing realm-aware. `None` when the
    /// emitter has no stamped path (string-parsed / outside ~/Projects), which
    /// keeps the match lenient.
    pub realm_path: Option<String>,
    /// This event's own in-memory lineage id — a monotonic `e<n>` handle
    /// assigned by `publish`. `None` on a freshly-built Event (before publish)
    /// and on hand-built events in tests. The causation-tree view keys the
    /// dispatch panel's tree on it (parent = the event whose `event_id` equals
    /// this event's `causation_id`).
    pub event_id: Option<String>,
    /// The `event_id` of the event that TRIGGERED this one — the last event the
    /// upstream aggregate published before this cascade fired. `None` for a root
    /// dispatch (no cascade), which makes this event a tree root. Stamped by the
    /// dispatcher from the cascade's upstream hint just before `publish`. Absent
    /// lineage → the UI falls back to a flat list, never crashes.
    pub causation_id: Option<String>,
}

type Listener = Box<dyn Fn(&Event)>;

pub struct EventBus {
    listeners: HashMap<String, Vec<Listener>>,
    global_listeners: Vec<Listener>,
    history: Vec<Event>,
    /// Monotonic in-memory event counter — `publish` mints `e<seq>` ids from it
    /// so every published event carries a stable, unique `event_id` the
    /// causation-tree view can key on. Process-lifetime, never reset (so ids
    /// stay globally unique even across `clear`).
    seq: u64,
    /// `"<type>::<id>"` → the `event_id` of the LAST event that aggregate
    /// published. A cascaded dispatch reads this for its upstream to stamp its
    /// own `causation_id`, threading the parent link without touching the
    /// (gated) durable Log. Latest write wins.
    last_event_by_agg: HashMap<String, String>,
}

impl Default for EventBus {
    fn default() -> Self {
        Self::new()
    }
}

impl EventBus {
    pub fn new() -> Self {
        EventBus {
            listeners: HashMap::new(),
            global_listeners: vec![],
            history: vec![],
            seq: 0,
            last_event_by_agg: HashMap::new(),
        }
    }

    pub fn subscribe<F: Fn(&Event) + 'static>(&mut self, event_name: &str, handler: F) {
        self.listeners
            .entry(event_name.to_string())
            .or_default()
            .push(Box::new(handler));
    }

    pub fn on_any<F: Fn(&Event) + 'static>(&mut self, handler: F) {
        self.global_listeners.push(Box::new(handler));
    }

    pub fn publish(&mut self, mut event: Event) {
        // Stamp an in-memory lineage id if the emitter did not (the normal case)
        // and remember it as this aggregate's latest, so a later cascade off the
        // same aggregate can cite it as its causation. Hand-built events that
        // already carry an `event_id` keep it (idempotent).
        if event.event_id.is_none() {
            self.seq += 1;
            event.event_id = Some(format!("e{}", self.seq));
        }
        if let Some(ref id) = event.event_id {
            self.last_event_by_agg.insert(
                format!("{}::{}", event.aggregate_type, event.aggregate_id),
                id.clone(),
            );
        }
        if let Some(handlers) = self.listeners.get(&event.name) {
            for handler in handlers {
                handler(&event);
            }
        }
        for handler in &self.global_listeners {
            handler(&event);
        }
        self.history.push(event);
    }

    /// The `event_id` of the last event a given aggregate published, if any.
    /// The dispatcher reads this for a cascade's upstream aggregate to stamp
    /// the cascaded event's `causation_id` — the parent link the causation-tree
    /// view renders. `None` when that aggregate has published nothing yet.
    pub fn last_event_for(&self, agg_type: &str, agg_id: &str) -> Option<String> {
        self.last_event_by_agg
            .get(&format!("{}::{}", agg_type, agg_id))
            .cloned()
    }

    pub fn events(&self) -> &[Event] {
        &self.history
    }

    pub fn clear(&mut self) {
        self.history.clear();
    }
}

#[cfg(test)]
mod lineage_tests {
    use super::*;

    fn ev(agg_type: &str, agg_id: &str, name: &str) -> Event {
        Event {
            name: name.to_string(),
            aggregate_type: agg_type.to_string(),
            aggregate_id: agg_id.to_string(),
            ..Default::default()
        }
    }

    #[test]
    fn publish_stamps_a_monotonic_event_id() {
        let mut bus = EventBus::new();
        bus.publish(ev("Order", "o1", "OrderPlaced"));
        bus.publish(ev("Order", "o1", "OrderPaid"));
        let ids: Vec<_> = bus.events().iter().map(|e| e.event_id.clone().unwrap()).collect();
        assert_eq!(ids, vec!["e1".to_string(), "e2".to_string()]);
    }

    #[test]
    fn last_event_for_tracks_the_latest_per_aggregate() {
        let mut bus = EventBus::new();
        assert_eq!(bus.last_event_for("Order", "o1"), None);
        bus.publish(ev("Order", "o1", "OrderPlaced"));
        assert_eq!(bus.last_event_for("Order", "o1").as_deref(), Some("e1"));
        // Latest write wins — a cascade cites the most recent upstream event.
        bus.publish(ev("Order", "o1", "OrderPaid"));
        assert_eq!(bus.last_event_for("Order", "o1").as_deref(), Some("e2"));
        // A different aggregate is tracked independently.
        assert_eq!(bus.last_event_for("Pizza", "p1"), None);
    }

    #[test]
    fn a_preset_event_id_is_preserved() {
        // Hand-built events (tests, replay) keep their own id — publish is idempotent.
        let mut bus = EventBus::new();
        let mut e = ev("Order", "o1", "OrderPlaced");
        e.event_id = Some("seed-7".to_string());
        bus.publish(e);
        assert_eq!(bus.last_event_for("Order", "o1").as_deref(), Some("seed-7"));
    }
}
