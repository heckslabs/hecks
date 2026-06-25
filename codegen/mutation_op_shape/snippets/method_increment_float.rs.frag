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
