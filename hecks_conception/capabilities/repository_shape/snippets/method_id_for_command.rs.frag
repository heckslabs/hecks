    /// Resolve the id for a command dispatch.
    ///
    ///   identified_by + attr present → use attr value (explicit)
    ///   identified_by + attr absent + exactly 1 record → use existing id
    ///     (singleton fallback: loop/policy caller didn't pass the id but
    ///      the record already exists; use it rather than counter-minting a
    ///      second record each tick. Mirrors inject_refs logic in mod.rs.)
    ///   identified_by + attr absent + 0 or >1 records → counter-mint
    ///   identified_by absent → counter-mint
    pub fn id_for_command(&mut self, attrs: &HashMap<String, Value>) -> String {
        if let Some(ref key) = self.identified_by {
            if let Some(Value::Str(s)) = attrs.get(key) {
                return s.clone();
            }
            // Singleton fallback: no id attr but exactly one existing record.
            if self.store.len() == 1 {
                if let Some(existing) = self.store.values().next() {
                    return existing.id.clone();
                }
            }
        }
        let id = self.next_id;
        self.next_id += 1;
        id.to_string()
    }
