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

use super::Value;
use std::collections::HashMap;

#[derive(Debug, Clone)]
pub struct Event {
    pub name: String,
    pub aggregate_type: String,
    pub aggregate_id: String,
    pub data: HashMap<String, Value>,
}

type Listener = Box<dyn Fn(&Event)>;

pub struct EventBus {
    listeners: HashMap<String, Vec<Listener>>,
    global_listeners: Vec<Listener>,
    history: Vec<Event>,
}

impl EventBus {
    pub fn new() -> Self {
        EventBus {
            listeners: HashMap::new(),
            global_listeners: vec![],
            history: vec![],
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

    pub fn publish(&mut self, event: Event) {
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

    pub fn events(&self) -> &[Event] {
        &self.history
    }

    pub fn clear(&mut self) {
        self.history.clear();
    }
}
