//! Middleware — the attachable dispatch stack (runtime projection of Gates)
//!
//! [antibody-exempt: rust/src/runtime/middleware.rs — kernel-floor runtime ;
//!  the dispatch middleware stack, the runtime projection of the Gate registry
//!  (aggregates/storehouse/storehouse.bluebook). Sibling of mod.rs, itself
//!  exempt. The bluebook is the declared truth ; this is its imperative leaf.]
//!
//! A `MiddlewareEntry` is one declared interceptor : a phase (before|after),
//! a `handler` lookup key the runtime resolves to an in-process verdict
//! function, a `pattern` selecting which dispatches it wraps, and an `order`.
//! The runtime hydrates this stack at boot from the standing gates (today the
//! self-seeded rbac-authorize gate ; once the `gating on dispatch` parser
//! surface lands, from `Storehouse::Gate.Active`). This is the runtime side of the
//! Gate registry (aggregates/storehouse/storehouse.bluebook) — the
//! MiddlewareStack is to Gates what the Procfile is to Drivers.
//!
//! A `before` handler is VETOING : the runtime resolves it to a verdict and a
//! Deny aborts the dispatch (see `Runtime::authorize_entry`). An `after`
//! handler is observe-only (not wired yet — no after-gates exist). `handler`
//! mirrors `Storehouse::Primitive.implementation` : the bluebook declares the
//! attachment, the runtime owns the verdict function the key names.
//!
//! Replaces the original closure-based stack (fire-and-forget, returned `()`,
//! could not deny) — it was empty and unused, so the cutover is clean.

/// When an interceptor runs relative to the aggregate handler.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Phase {
    Before,
    After,
}

impl Phase {
    /// Parse a bluebook `phase` string. Unknown values map to `Before` —
    /// fail-safe : an unrecognised phase still gates rather than silently
    /// becoming observe-only.
    pub fn parse(s: &str) -> Phase {
        match s {
            "after" => Phase::After,
            _ => Phase::Before,
        }
    }
}

/// One declared interceptor attached to the dispatch path — the runtime
/// projection of a `Storehouse::Gate` record.
#[derive(Debug, Clone)]
pub struct MiddlewareEntry {
    pub name: String,
    pub phase: Phase,
    pub handler: String,
    pub pattern: String,
    pub order: i64,
}

/// The ordered set of attached interceptors. Hydrated at boot ; iterated per
/// dispatch. Before-entries gate (vetoing) ; after-entries observe.
#[derive(Debug, Clone, Default)]
pub struct MiddlewareStack {
    entries: Vec<MiddlewareEntry>,
}

impl MiddlewareStack {
    pub fn new() -> Self {
        MiddlewareStack { entries: vec![] }
    }

    /// Build from entries, ordered by `order` (lower first), ties broken by
    /// name for determinism — so authn (a lower order) runs before authz.
    pub fn from_entries(mut entries: Vec<MiddlewareEntry>) -> Self {
        entries.sort_by(|a, b| a.order.cmp(&b.order).then_with(|| a.name.cmp(&b.name)));
        MiddlewareStack { entries }
    }

    /// The before-phase interceptors whose pattern matches `command`, in order.
    pub fn before_matching<'a>(
        &'a self,
        command: &'a str,
    ) -> impl Iterator<Item = &'a MiddlewareEntry> {
        self.entries
            .iter()
            .filter(move |e| e.phase == Phase::Before && pattern_matches(&e.pattern, command))
    }

    pub fn count(&self) -> usize {
        self.entries.len()
    }
}

/// Does a registry `pattern` select `command` ?
/// - `"*"` matches every command (the cross-cutting case — authn/authz).
/// - a trailing-`*` pattern matches by prefix (`"Hecks::Framework::Agent::*"`).
/// - otherwise an exact match.
pub fn pattern_matches(pattern: &str, command: &str) -> bool {
    if pattern == "*" {
        return true;
    }
    if let Some(prefix) = pattern.strip_suffix('*') {
        return command.starts_with(prefix);
    }
    pattern == command
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pattern_star_matches_all() {
        assert!(pattern_matches("*", "Anything::At.All"));
    }

    #[test]
    fn pattern_prefix_matches_by_prefix() {
        assert!(pattern_matches(
            "Hecks::Framework::Agent::*",
            "Hecks::Framework::Agent::Role.Define"
        ));
        assert!(!pattern_matches(
            "Hecks::Framework::Agent::*",
            "Hecks::Framework::Governance::Policy.Propose"
        ));
    }

    #[test]
    fn pattern_exact_matches_exact() {
        assert!(pattern_matches("Order.PlaceOrder", "Order.PlaceOrder"));
        assert!(!pattern_matches("Order.PlaceOrder", "Order.CancelOrder"));
    }

    #[test]
    fn from_entries_sorts_by_order_then_name() {
        let s = MiddlewareStack::from_entries(vec![
            MiddlewareEntry { name: "b".into(), phase: Phase::Before, handler: "h".into(), pattern: "*".into(), order: 20 },
            MiddlewareEntry { name: "a".into(), phase: Phase::Before, handler: "h".into(), pattern: "*".into(), order: 10 },
            MiddlewareEntry { name: "c".into(), phase: Phase::Before, handler: "h".into(), pattern: "*".into(), order: 10 },
        ]);
        let names: Vec<_> = s.before_matching("X.Y").map(|e| e.name.as_str()).collect();
        assert_eq!(names, vec!["a", "c", "b"]);
    }

    #[test]
    fn before_matching_filters_phase_and_pattern() {
        let s = MiddlewareStack::from_entries(vec![
            MiddlewareEntry { name: "authz".into(), phase: Phase::Before, handler: "rbac-authorize".into(), pattern: "*".into(), order: 20 },
            MiddlewareEntry { name: "after-only".into(), phase: Phase::After, handler: "log".into(), pattern: "*".into(), order: 5 },
            MiddlewareEntry { name: "scoped".into(), phase: Phase::Before, handler: "x".into(), pattern: "Agent::*".into(), order: 1 },
        ]);
        let names: Vec<_> = s.before_matching("Order.PlaceOrder").map(|e| e.name.as_str()).collect();
        assert_eq!(names, vec!["authz"]); // after-only excluded by phase, scoped excluded by pattern
    }
}
