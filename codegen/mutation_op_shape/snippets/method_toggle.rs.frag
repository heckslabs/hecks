    pub fn toggle(&mut self, field: &str) {
        let current = match self.fields.get(field) {
            Some(Value::Bool(b)) => *b,
            _ => false,
        };
        self.fields
            .insert(field.to_string(), Value::Bool(!current));
    }
