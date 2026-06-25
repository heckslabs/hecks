    pub fn get(&self, field: &str) -> &Value {
        self.fields.get(field).unwrap_or(&Value::Null)
    }
