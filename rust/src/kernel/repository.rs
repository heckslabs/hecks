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

/// `refuse_role_mismatch` — `CommandRules::Authorization`
/// (`lib/hecksagain/runtime/command_rules/authorization.rb`), read
/// directly:
/// ```ruby
/// def refuse_role_mismatch(command)
///   caller = Caller.current
///   return unless caller
///   return if command.role.to_s.empty?
///   return if caller.role == command.role
///   raise Unauthorized, ...
/// end
/// ```
/// Doubly opt-in, matched exactly: no bound caller (`caller_role: None` —
/// no `role:` on this step at all, the ordinary case for all but a
/// deliberately role-checking corpus fixture) → unchecked; no role the
/// command itself declared (`command_role: None`) → unchecked. Ruby's
/// caller comes from thread-local ambient state (`Caller.current`,
/// `Hecksagain.as_caller`) that this kernel has no analogue for — a
/// step's own `role:` key plays that part instead, read once at the CLI
/// boundary (`cli.rs`) and threaded through `orchestrate`'s OUTERMOST
/// dispatch only, exactly mirroring `Dispatcher#reenter`'s own
/// `Caller.without`: a policy/process-manager REACTION never carries a
/// caller in Ruby either, so a reaction's own re-entry into `orchestrate`
/// always passes `None` here, never the triggering step's role.
pub fn check_role(command_role: Option<&str>, command_name: &str, caller_role: Option<&str>) -> Result<(), super::Refusal> {
    let (Some(caller), Some(role)) = (caller_role, command_role) else { return Ok(()) };
    if caller == role {
        return Ok(());
    }
    Err(super::Refusal::Unauthorized(format!("{command_name} refused — role: {role}, and the caller stated {caller}")))
}
