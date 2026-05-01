    pub fn decrement_float(&mut self, field: &str, amount: f64) {
        let current = current_numeric(self.fields.get(field));
        let new_val = current - amount;
        self.fields
            .insert(field.to_string(), Value::Str(format_numeric(new_val)));
    }
