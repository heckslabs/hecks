    /// Append `value` only when no value-equal element is already present —
    /// the idempotent sibling of `append`. Mirrors `remove`'s value-equality
    /// (`*x != value`) : a `list_of(VO)` dedupes by full value, since a value
    /// object has no identity. Backs `then_set :field, append_unique:`, so a
    /// re-fired establishment policy re-appends an identical record as a no-op.
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
