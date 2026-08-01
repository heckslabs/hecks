use super::heki;
use crate::ports::persistence::ReplicationEntry;
use crate::runtime::{value_bridge, AggregateState, PersistenceAdapter};
use serde_json::json;
use std::collections::HashMap;
use std::fs::OpenOptions;
use std::io::{BufRead, BufReader, Write};

pub struct HekiRepository {
    path: String,
    journal_path: String,
    store: HashMap<String, AggregateState>,
}

impl HekiRepository {
    // NO `identified_by`. A repository is handed an id that is already
    // derived — `identity::of` follows every declared path and joins them —
    // so it never had a question the identity could answer. The field existed
    // for `id_for_command` alone, and that minted.
    pub fn new(aggregate: &str, dir: &str) -> Result<Self, String> {
        let path = format!(
            "{}/{}.heki",
            dir.trim_end_matches('/'),
            crate::naming::snake(aggregate)
        );

        if let Some(parent) = std::path::Path::new(&path).parent() {
            std::fs::create_dir_all(parent)
                .map_err(|e| format!("cannot create {:?}: {}", parent, e))?;
        }

        let journal_path = format!("{}.journal", path);
        let raw = heki::read(&path)?;
        let mut store = HashMap::new();

        for (id, record) in raw {
            let fields: serde_json::Map<String, serde_json::Value> = record.into_iter().collect();
            store.insert(id.clone(), value_bridge::to_state(&id, &fields));
        }
        Self::replay_journal(&journal_path, &mut store)?;

        Ok(Self {
            path,
            journal_path,
            store,
        })
    }

    fn flush(&self) -> Result<(), String> {
        let records: heki::Store = self
            .store
            .iter()
            .map(|(id, state)| {
                (
                    id.clone(),
                    value_bridge::from_state(state).into_iter().collect(),
                )
            })
            .collect();

        heki::write(
            &self.path,
            &records,
            heki::WriteContext::OutOfBand { reason: "persist" },
        )
    }

    fn append_entry(
        &self,
        operation: &str,
        id: &str,
        state: Option<&AggregateState>,
        mirrors: &[String],
    ) -> Result<(), String> {
        let entry = json!({
            "operation": operation,
            "id": id,
            "state": state.map(value_bridge::from_state),
            "mirrors": mirrors,
        });
        let mut journal = OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.journal_path)
            .map_err(|error| format!("cannot open {}: {error}", self.journal_path))?;
        writeln!(journal, "{entry}")
            .and_then(|_| journal.sync_all())
            .map_err(|error| format!("cannot append {}: {error}", self.journal_path))
    }

    fn replay_journal(
        path: &str,
        store: &mut HashMap<String, AggregateState>,
    ) -> Result<(), String> {
        let journal = match std::fs::File::open(path) {
            Ok(file) => file,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
            Err(error) => return Err(format!("cannot read {}: {}", path, error)),
        };

        for line in BufReader::new(journal).lines() {
            let line = line.map_err(|error| format!("{}: {}", path, error))?;
            let entry: serde_json::Value = serde_json::from_str(&line)
                .map_err(|error| format!("{}: json error: {}", path, error))?;
            let id = entry
                .get("id")
                .and_then(serde_json::Value::as_str)
                .ok_or_else(|| format!("{}: journal entry has no id", path))?;

            match entry.get("operation").and_then(serde_json::Value::as_str) {
                Some("save") => {
                    let fields = entry
                        .get("state")
                        .and_then(serde_json::Value::as_object)
                        .ok_or_else(|| format!("{}: save entry has no state", path))?
                        .clone();
                    store.insert(id.to_string(), value_bridge::to_state(id, &fields));
                }
                Some("delete") => {
                    store.remove(id);
                }
                Some(operation) => {
                    return Err(format!(
                        "{}: unknown journal operation {:?}",
                        path, operation
                    ))
                }
                None => return Err(format!("{}: journal entry has no operation", path)),
            }
        }
        Ok(())
    }

    fn entries(&self) -> Result<Vec<ReplicationEntry>, String> {
        let journal = match std::fs::File::open(&self.journal_path) {
            Ok(file) => file,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(vec![]),
            Err(error) => return Err(format!("cannot read {}: {}", self.journal_path, error)),
        };

        BufReader::new(journal)
            .lines()
            .map(|line| {
                let line = line.map_err(|error| format!("{}: {}", self.journal_path, error))?;
                let entry: serde_json::Value = serde_json::from_str(&line)
                    .map_err(|error| format!("{}: json error: {}", self.journal_path, error))?;
                let id = entry.get("id").and_then(serde_json::Value::as_str)
                    .ok_or_else(|| format!("{}: journal entry has no id", self.journal_path))?;
                let operation = entry.get("operation").and_then(serde_json::Value::as_str)
                    .ok_or_else(|| format!("{}: journal entry has no operation", self.journal_path))?;
                let state = match operation {
                    "save" => {
                        let fields = entry.get("state").and_then(serde_json::Value::as_object)
                            .ok_or_else(|| format!("{}: save entry has no state", self.journal_path))?;
                        Some(value_bridge::to_state(id, fields))
                    }
                    "delete" => None,
                    other => return Err(format!("{}: unknown journal operation {:?}", self.journal_path, other)),
                };
                let mirrors = entry.get("mirrors").and_then(serde_json::Value::as_array)
                    .map(|names| names.iter().filter_map(serde_json::Value::as_str).map(str::to_string).collect())
                    .unwrap_or_default();
                Ok(ReplicationEntry { operation: operation.to_string(), id: id.to_string(), state, mirrors })
            })
            .collect()
    }
}

impl PersistenceAdapter for HekiRepository {
    fn find(&self, id: &str) -> Option<&AggregateState> {
        self.store.get(id)
    }

    fn find_mut(&mut self, id: &str) -> Option<&mut AggregateState> {
        self.store.get_mut(id)
    }

    fn all(&self) -> Vec<&AggregateState> {
        self.store.values().collect()
    }

    fn count(&self) -> usize {
        self.store.len()
    }

    fn save(&mut self, state: AggregateState, _ctx: heki::WriteContext<'_>) -> Result<(), String> {
        self.save_with_mirrors(state, vec![], _ctx)
    }

    fn save_with_mirrors(&mut self, state: AggregateState, mirrors: Vec<String>, _ctx: heki::WriteContext<'_>) -> Result<(), String> {
        self.append_entry("save", &state.id, Some(&state), &mirrors)?;
        self.store.insert(state.id.clone(), state);
        self.flush()
    }

    fn delete(&mut self, id: &str, _ctx: heki::WriteContext<'_>) -> Result<(), String> {
        self.delete_with_mirrors(id, vec![], _ctx)
    }

    fn delete_with_mirrors(&mut self, id: &str, mirrors: Vec<String>, _ctx: heki::WriteContext<'_>) -> Result<(), String> {
        self.append_entry("delete", id, None, &mirrors)?;
        self.store.remove(id);
        self.flush()
    }

    fn replication_entries(&self) -> Result<Vec<ReplicationEntry>, String> { self.entries() }

    fn query(
        &self,
        _wheres: &[crate::ir::WhereClause],
        _attrs: &HashMap<String, String>,
    ) -> Option<Vec<AggregateState>> {
        None
    }

    // A record is seeded under the id it already carries. The counter upkeep
    // that used to be here — "raise the next id above this one" — was the
    // mint's bookkeeping, not the store's.
    fn seed_record(&mut self, state: AggregateState) {
        self.store.insert(state.id.clone(), state);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    // `Value` is no longer in this file's own imports — the only signature
    // that needed it was `id_for_command`.
    use crate::runtime::Value;

    #[test]
    fn an_authoritative_append_carries_its_mirror_intent() {
        let dir = std::env::temp_dir().join(format!("hecksagain-heki-mirror-{}", crate::util::uuid_v4()));
        let mut repository = HekiRepository::new("Account", dir.to_str().unwrap()).unwrap();
        let mut state = AggregateState::new("a");
        state.set("balance", Value::Int(500));

        repository.save_with_mirrors(
            state,
            vec!["Sqlite".to_string()],
            heki::WriteContext::OutOfBand { reason: "test" },
        ).unwrap();

        let entries = repository.replication_entries().unwrap();
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].mirrors, vec!["Sqlite"]);
        assert_eq!(entries[0].state.as_ref().unwrap().get("balance"), &Value::Int(500));
        let _ = std::fs::remove_dir_all(dir);
    }
}
