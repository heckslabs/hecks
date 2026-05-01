    pub fn increment(&mut self, field: &str, amount: i64) {
        let current = match self.fields.get(field) {
            Some(Value::Int(n)) => *n,
            _ => 0,
        };
        self.fields
            .insert(field.to_string(), Value::Int(current + amount));
    }
