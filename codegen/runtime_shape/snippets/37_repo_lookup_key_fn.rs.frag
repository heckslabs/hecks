/// i142 Tier 2 — name-only lookup helper for callers that don't yet
/// carry context info (public Runtime::find/all, behaviors runners,
/// CommandResult-driven main loops). Scans for an exact match first
/// (legacy / context-less repository), then for any "<ctx>::<name>"
/// key. With name uniqueness inside the loaded domain (the common
/// case), this is unambiguous. True same-name collisions across
/// contexts surface as nondeterministic picks here — those callers
/// should be migrated to keyed lookup as Tier 3 progresses.
pub fn repo_lookup_key(repositories: &HashMap<String, Repository>, name: &str) -> Option<String> {
    if repositories.contains_key(name) {
        return Some(name.to_string());
    }
    let suffix = format!("::{}", name);
    repositories.keys().find(|k| k.ends_with(&suffix)).cloned()
}

