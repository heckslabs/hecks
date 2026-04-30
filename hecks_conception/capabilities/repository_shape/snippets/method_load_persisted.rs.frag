    fn load_persisted(&mut self) {
        let Some(ref dir) = self.data_dir else { return };
        let path = self.heki_path_self(dir);
        // i142 Tier 2 — auto-migration : when reading from the new
        // context-prefixed path returns nothing, but the flat
        // pre-context path has data, MOVE the flat file into the
        // context dir. One-shot lazy migration ; runs on the first
        // load of each aggregate after Tier 2 ships. Subsequent
        // reads/writes go through the new path natively.
        if self.context.is_some() {
            let new_records = heki::read(&path).unwrap_or_default();
            if new_records.is_empty() {
                let flat_path = heki::path_for(dir, &self.aggregate_type, None);
                if std::path::Path::new(&flat_path).exists() && flat_path != path {
                    if let Some(parent) = std::path::Path::new(&path).parent() {
                        let _ = std::fs::create_dir_all(parent);
                    }
                    let _ = std::fs::rename(&flat_path, &path);
                }
            }
        }
        let records = heki::read(&path).unwrap_or_default();
        for (_, rec) in &records {
            let id = rec.get("id")
                .and_then(|v| v.as_str())
                .unwrap_or("1")
                .to_string();
            if let Ok(n) = id.parse::<u64>() {
                if n >= self.next_id { self.next_id = n + 1; }
            }
            let mut state = AggregateState::new(&id);
            for (key, val) in rec {
                if key != "id" && key != "created_at" && key != "updated_at" {
                    state.set(key, from_json(val));
                }
            }
            self.store.insert(id, state);
        }
        // Quiet by default — every dispatch boots a fresh runtime and
        // would otherwise spam dozens of "loaded N records from disk"
        // lines (visible especially in the narrow PostToolUse hook
        // output column). Set HECKS_REPO_VERBOSE=1 to see them when
        // debugging boot-time loading.
        if !self.store.is_empty()
            && std::env::var("HECKS_REPO_VERBOSE").ok().as_deref() == Some("1")
        {
            eprintln!("  loaded {} {} records from disk",
                self.store.len(), self.aggregate_type);
        }
    }
