    pub fn increment(&mut self, field: &str, amount: i64) {
        // Reads through Int / numeric-Str / single-value VO map (see decrement).
        let current = current_numeric(self.fields.get(field)) as i64;
        self.fields
            .insert(field.to_string(), Value::Int(current + amount));
    }
