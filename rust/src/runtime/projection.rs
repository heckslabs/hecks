//! Projection — CQRS read models built from events
//!
//! A projection watches events and maintains a derived view.
//! Each projection has event handlers that upsert/delete rows,
//! and named queries that read them.
//!
//! Usage:
//!   let mut proj = Projection::new("PizzaList");
//!   proj.apply(&event);
//!   let rows = proj.query_all();

use super::{Event, Value};
use std::collections::HashMap;

type EventHandler = Box<dyn Fn(&Event, &mut ProjectionState)>;
type QueryFn = Box<dyn Fn(&ProjectionState) -> Vec<HashMap<String, Value>>>;

pub struct ProjectionState {
    pub rows: HashMap<String, HashMap<String, Value>>,
}

impl ProjectionState {
    pub fn upsert(&mut self, id: &str, fields: HashMap<String, Value>) {
        let row = self.rows.entry(id.to_string()).or_default();
        for (k, v) in fields {
            row.insert(k, v);
        }
    }

    pub fn delete(&mut self, id: &str) {
        self.rows.remove(id);
    }

    pub fn all(&self) -> Vec<&HashMap<String, Value>> {
        self.rows.values().collect()
    }
}

pub struct Projection {
    pub name: String,
    handlers: HashMap<String, EventHandler>,
    global_handlers: Vec<EventHandler>,
    queries: HashMap<String, QueryFn>,
    state: ProjectionState,
}

impl Projection {
    pub fn new(name: &str) -> Self {
        Projection {
            name: name.to_string(),
            handlers: HashMap::new(),
            global_handlers: vec![],
            queries: HashMap::new(),
            state: ProjectionState {
                rows: HashMap::new(),
            },
        }
    }

    pub fn on_event<F: Fn(&Event, &mut ProjectionState) + 'static>(
        &mut self,
        event_name: &str,
        handler: F,
    ) {
        if event_name == "*" {
            self.global_handlers.push(Box::new(handler));
        } else {
            self.handlers
                .insert(event_name.to_string(), Box::new(handler));
        }
    }

    pub fn add_query<F: Fn(&ProjectionState) -> Vec<HashMap<String, Value>> + 'static>(
        &mut self,
        name: &str,
        query: F,
    ) {
        self.queries.insert(name.to_string(), Box::new(query));
    }

    pub fn apply(&mut self, event: &Event) {
        if let Some(handler) = self.handlers.get(&event.name) {
            handler(event, &mut self.state);
        }
        for handler in &self.global_handlers {
            handler(event, &mut self.state);
        }
    }

    pub fn query(&self, name: &str) -> Vec<HashMap<String, Value>> {
        match self.queries.get(name) {
            Some(q) => q(&self.state),
            None => vec![],
        }
    }

    pub fn query_all(&self) -> Vec<&HashMap<String, Value>> {
        self.state.all()
    }

    pub fn count(&self) -> usize {
        self.state.rows.len()
    }
}

/// Auto-projection: mirrors aggregate state from events.
/// Every domain gets one per aggregate for free.
pub fn auto_projection(aggregate_name: &str) -> Projection {
    let mut proj = Projection::new(&format!("{}List", aggregate_name));
    let agg_name = aggregate_name.to_string();

    proj.on_event("*", move |event, state| {
        if event.aggregate_type == agg_name {
            let mut fields = event.data.clone();
            fields.insert(
                "_id".to_string(),
                Value::Str(event.aggregate_id.clone()),
            );
            state.upsert(&event.aggregate_id, fields);
        }
    });

    proj
}
