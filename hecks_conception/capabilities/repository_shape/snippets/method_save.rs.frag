    pub fn save(&mut self, state: AggregateState, ctx: heki::WriteContext<'_>) {
        self.store.insert(state.id.clone(), state);
        if let Some(ref dir) = self.data_dir {
            let path = self.heki_path_self(dir);
            if let Some(parent) = std::path::Path::new(&path).parent() {
                let _ = std::fs::create_dir_all(parent);
            }
            let mut heki_store = heki::Store::new();
            for (id, s) in &self.store {
                let mut rec = heki::Record::new();
                rec.insert("id".into(), serde_json::Value::String(id.clone()));
                for (key, val) in &s.fields {
                    rec.insert(key.clone(), to_json(val));
                }
                heki_store.insert(id.clone(), rec);
            }
            let _ = heki::write(&path, &heki_store, ctx);
        }
    }
