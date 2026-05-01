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

