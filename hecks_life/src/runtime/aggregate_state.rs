//! AggregateState — dynamic bag of fields
//!
//! Aggregates are not typed structs — they're Value maps
//! shaped by the Bluebook IR at runtime.
//!
//! Usage:
//!   let mut state = AggregateState::new("pizza_1");
//!   state.set("name", Value::Str("Margherita".into()));

use super::Value;
use std::collections::HashMap;

#[derive(Debug, Clone)]
pub struct AggregateState {
    pub id: String,
    pub fields: HashMap<String, Value>,
}

impl AggregateState {
    pub fn new(id: &str) -> Self {
        AggregateState {
            id: id.to_string(),
            fields: HashMap::new(),
        }
    }

    pub fn get(&self, field: &str) -> &Value {
        self.fields.get(field).unwrap_or(&Value::Null)
    }

    pub fn set(&mut self, field: &str, value: Value) {
        self.fields.insert(field.to_string(), value);
    }

    pub fn append(&mut self, field: &str, value: Value) {
        let list = self
            .fields
            .entry(field.to_string())
            .or_insert_with(|| Value::List(vec![]));
        if let Value::List(ref mut v) = list {
            v.push(value);
        }
    }

    pub fn increment(&mut self, field: &str, amount: i64) {
        let current = match self.fields.get(field) {
            Some(Value::Int(n)) => *n,
            _ => 0,
        };
        self.fields
            .insert(field.to_string(), Value::Int(current + amount));
    }

    pub fn decrement(&mut self, field: &str, amount: i64) {
        let current = match self.fields.get(field) {
            Some(Value::Int(n)) => *n,
            _ => 0,
        };
        self.fields
            .insert(field.to_string(), Value::Int(current - amount));
    }

    pub fn toggle(&mut self, field: &str) {
        let current = match self.fields.get(field) {
            Some(Value::Bool(b)) => *b,
            _ => false,
        };
        self.fields
            .insert(field.to_string(), Value::Bool(!current));
    }
}
