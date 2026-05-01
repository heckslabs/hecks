    /// Float-aware set — i106 Multiply / Decay / Clamp. The new value
    /// is rendered as the same numeric Str representation
    /// `increment_float` uses, so downstream comparisons (givens,
    /// queries) coerce identically across +/- and ×/clamp paths.
    pub fn set_float(&mut self, field: &str, value: f64) {
        self.fields
            .insert(field.to_string(), Value::Str(format_numeric(value)));
    }
