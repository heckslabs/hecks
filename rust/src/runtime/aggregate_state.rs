
use super::Value;
use std::collections::HashMap;

#[derive(Debug, Clone)]
pub struct AggregateState {
    pub id: String,
    pub fields: HashMap<String, Value>,
    pub deleted: bool,
}

impl AggregateState {
    pub fn new(id: &str) -> Self {
        AggregateState {
            id: id.to_string(),
            fields: HashMap::new(),
            deleted: false,
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
        let current = current_numeric(self.fields.get(field)) as i64;
        self.fields
            .insert(field.to_string(), Value::Int(current + amount));
    }

    pub fn decrement(&mut self, field: &str, amount: i64) {
        let current = current_numeric(self.fields.get(field)) as i64;
        self.fields
            .insert(field.to_string(), Value::Int(current - amount));
    }

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

    pub fn remove(&mut self, field: &str, value: Value) {
        if let Some(Value::List(ref mut v)) = self.fields.get_mut(field) {
            v.retain(|x| *x != value);
        }
    }

    pub fn append_unique(&mut self, field: &str, value: Value) {
        let list = self
            .fields
            .entry(field.to_string())
            .or_insert_with(|| Value::List(vec![]));
        if let Value::List(ref mut v) = list {
            if !v.contains(&value) {
                v.push(value);
            }
        }
    }
}

fn current_numeric(v: Option<&Value>) -> f64 {
    match v {
        Some(Value::Int(n)) => *n as f64,
        Some(Value::Str(s)) => s.parse::<f64>().unwrap_or(0.0),
        Some(Value::Map(m)) => m.get("value").map(|inner| current_numeric(Some(inner))).unwrap_or(0.0),
        _ => 0.0,
    }
}

fn format_numeric(n: f64) -> String {
    if n == n.trunc() && n.abs() < 1e15 {
        format!("{}", n as i64)
    } else {
        format!("{}", n)
    }
}
