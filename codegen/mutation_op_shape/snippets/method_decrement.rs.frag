    pub fn decrement(&mut self, field: &str, amount: i64) {
        // current_numeric reads the field whether it is stored as Int, a numeric
        // Str (an un-coerced dispatch input), or a single-value VO map — so a
        // numeric mutation never silently treats "2" as 0 (the deciderate saga
        // bug : OpenRound stored games_remaining as Str("2"), and the old
        // Int-only match read it as 0, yielding -1 instead of 1).
        let current = current_numeric(self.fields.get(field)) as i64;
        self.fields
            .insert(field.to_string(), Value::Int(current - amount));
    }
