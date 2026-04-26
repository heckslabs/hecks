//! AggregateState — dynamic bag of fields
//!
//! Aggregates are not typed structs — they're Value maps
//! shaped by the Bluebook IR at runtime.
//!
//! Usage:
//!   let mut state = AggregateState::new("pizza_1");
//!   state.set("name", Value::Str("Margherita".into()));
//!
//! [antibody-exempt: i106 dsl-mutation-primitives — adds `set_float`
//!  for Multiply / Clamp / Decay. Same retirement contract as ir.rs.]

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

    /// Float-aware increment. The Bluebook DSL allows fractional
    /// increments (`then_set :fatigue, increment: 0.01`); the int-only
    /// `increment()` would silently round 0.01 to 1 (after the
    /// `unwrap_or(1)` fallback in the interpreter), so fatigue would
    /// track beats one-to-one instead of accumulating slowly. This
    /// path stores the result as a `Str` representation of the float
    /// so it round-trips through the DSL's numeric coercion.
    pub fn increment_float(&mut self, field: &str, amount: f64) {
        let current = current_numeric(self.fields.get(field));
        let new_val = current + amount;
        self.fields
            .insert(field.to_string(), Value::Str(format_numeric(new_val)));
    }

    pub fn decrement_float(&mut self, field: &str, amount: f64) {
        let current = current_numeric(self.fields.get(field));
        let new_val = current - amount;
        self.fields
            .insert(field.to_string(), Value::Str(format_numeric(new_val)));
    }

    /// Float-aware set — i106 Multiply / Decay / Clamp. The new value
    /// is rendered as the same numeric Str representation
    /// `increment_float` uses, so downstream comparisons (givens,
    /// queries) coerce identically across +/- and ×/clamp paths.
    pub fn set_float(&mut self, field: &str, value: f64) {
        self.fields
            .insert(field.to_string(), Value::Str(format_numeric(value)));
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

fn current_numeric(v: Option<&Value>) -> f64 {
    match v {
        Some(Value::Int(n)) => *n as f64,
        Some(Value::Str(s)) => s.parse::<f64>().unwrap_or(0.0),
        _ => 0.0,
    }
}

/// Format a numeric value for storage. Whole-valued floats stringify
/// as "3" (not "3.0") so they keep parity with Int(3) for downstream
/// equality comparisons; fractional values keep their decimal form.
fn format_numeric(n: f64) -> String {
    if n == n.trunc() && n.abs() < 1e15 {
        format!("{}", n as i64)
    } else {
        format!("{}", n)
    }
}
