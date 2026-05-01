    pub fn append(&mut self, field: &str, value: Value) {
        let list = self
            .fields
            .entry(field.to_string())
            .or_insert_with(|| Value::List(vec![]));
        if let Value::List(ref mut v) = list {
            v.push(value);
        }
    }
