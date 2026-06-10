    pub fn remove(&mut self, field: &str, value: Value) {
        if let Some(Value::List(ref mut v)) = self.fields.get_mut(field) {
            v.retain(|x| *x != value);
        }
    }
