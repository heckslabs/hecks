// Generic over the record type — one impl (InMemoryRepository<T>) serves
// every generated aggregate, nothing domain-specific here.
//
// `find` -> `None` for an id never stored, `save` upserts by id. The
// persistence contract itself — which methods a real adapter must answer,
// which are delegated without a presence check, which are optional
// passthroughs, and that `delete`'s return value is explicitly not part of
// the contract — is documented in full in docs/guides/writing-an-adapter.md;
// this trait is a Rust-shaped minimal reading of that same contract
// (`find`/`save`/`all`/`count`), not a second, undocumented one.

use std::collections::BTreeMap;

pub trait Repository<T: Clone> {
    fn find(&self, id: &str) -> Option<T>;
    fn save(&mut self, id: &str, record: T);
    fn all(&self) -> Vec<T>;
    fn count(&self) -> usize;
}

#[derive(Default)]
pub struct InMemoryRepository<T: Clone> {
    records: BTreeMap<String, T>,
}

impl<T: Clone> InMemoryRepository<T> {
    pub fn new() -> Self {
        Self { records: BTreeMap::new() }
    }

    /// `(id, record)` pairs — `Repository::all` alone discards the id,
    /// which the CLI's `instances` dump needs (Ruby's own oracle output
    /// keys each instance `"Domain::Aggregate#id"`, per
    /// `bin/rust_conformance`'s `comparable["instances"]`). Kept on the
    /// concrete type rather than added to the `Repository` trait — nothing
    /// generated dispatches through this method, only the hand-written CLI
    /// does, and every `Store` (rust/project/json_codec.rb's
    /// `emit_registry`) holds `InMemoryRepository` concretely already.
    pub fn entries(&self) -> impl Iterator<Item = (&String, &T)> {
        self.records.iter()
    }
}

impl<T: Clone> Repository<T> for InMemoryRepository<T> {
    fn find(&self, id: &str) -> Option<T> {
        self.records.get(id).cloned()
    }

    fn save(&mut self, id: &str, record: T) {
        self.records.insert(id.to_string(), record);
    }

    fn all(&self) -> Vec<T> {
        self.records.values().cloned().collect()
    }

    fn count(&self) -> usize {
        self.records.len()
    }
}

/// `resolve_references` — `CommandRules::References#resolve_references`
/// (`lib/hecksagain/runtime/command_rules/references.rb`), read directly.
/// Hand-written and generic, unlike almost every other per-command check,
/// because its one caller is `registry.rs`'s generated `dispatch_by_name`
/// (`rust/project/reactions.rb`'s `emit_reference_check`) — the same place
/// Ruby's own version reaches through `@registry.repository(domain,
/// target)`, i.e. a repository OTHER than the dispatching command's own.
/// Nothing about the check itself is domain-specific; only WHICH repo and
/// WHICH command attribute to check is (generated, per command).
///
/// `value` empty is treated as "no check", mirroring Ruby's own
/// `next if key.to_s.empty?` (documented there as effectively unreachable
/// in practice — a non-string reference value is already refused earlier,
/// at the payload gate).
pub fn check_reference<T: Clone>(
    repo: &impl Repository<T>,
    value: &str,
    target: &'static str,
    heads: &'static str,
) -> Result<(), super::Refusal> {
    if value.is_empty() || repo.find(value).is_some() {
        return Ok(());
    }
    Err(super::Refusal::NotFound(format!("no {target} with {heads} {value:?}")))
}
