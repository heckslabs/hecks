//! EventBus — in-process pub/sub
//!
//! Commands emit events. Policies and subscribers listen.
//! Global listeners see everything; named listeners filter by event name.
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
