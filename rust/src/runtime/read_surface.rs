//! read_surface — the runtime READ door : find / all (context-disambiguated
//! repository reads), the projection registry (add_projection /
//! query_projection), resolve_query + the gated `query` mirror of dispatch,
//! and run_interactive (the terminal adapter loop).
//!
//! Cask extracted VERBATIM from runtime/mod.rs (shrink-mod phase B, wave 3).
//!
//! [antibody-exempt: rust/src/runtime/read_surface.rs — kernel-floor read
//!  door, relocated verbatim from mod.rs blanket.]

use super::*;

impl Runtime {
    pub fn find(&self, aggregate_name: &str, id: &str) -> Option<&AggregateState> {
        // Exact-key fast path — when the caller passes either the bare
        // name (single-context corpus) or a fully-qualified
        // `Context::Name` key (post-i142), match it directly.
        if let Some(repo) = self.repositories.get(aggregate_name) {
            if let Some(state) = repo.find(id) {
                return Some(state);
            }
        }
        // Context-disambiguation path — when multiple contexts declare
        // an aggregate with the same name (e.g. self/Conversation,
        // capabilities/cloudflare_deploy/MiettePhone::Conversation),
        // repo_lookup_key picks
        // a first hash-iter match nondeterministically. Walk every
        // key ending with `::<name>` and return the FIRST one whose
        // store actually carries the id — the id itself disambiguates
        // which context the dispatch landed in.
        let suffix = format!("::{}", aggregate_name);
        for (key, repo) in &self.repositories {
            if key.ends_with(&suffix) {
                if let Some(state) = repo.find(id) {
                    return Some(state);
                }
            }
        }
        None
    }

    pub fn all(&self, aggregate_name: &str) -> Vec<&AggregateState> {
        match repo_lookup_key(&self.repositories, aggregate_name) {
            Some(key) => self.repositories.get(&key).map(|repo| repo.all()).unwrap_or_default(),
            None => Vec::new(),
        }
    }


    pub fn add_projection(&mut self, projection: Projection) {
        self.projections.push(projection);
    }

    pub fn query_projection(
        &self,
        projection_name: &str,
        query_name: &str,
    ) -> Vec<HashMap<String, Value>> {
        for proj in &self.projections {
            if proj.name == projection_name {
                return proj.query(query_name);
            }
        }
        vec![]
    }
    /// Resolve a query — search IR or return aggregate state.
    ///
    /// i101 — when the IR Query carries structured wheres / order_by /
    /// limit, the executor walks repo.all() and applies them in order :
    /// filter → sort → truncate. The opaque-Ruby-block era is retired.
    ///
    /// Back-compat unqualified entry point. Delegates to
    /// `resolve_query_qualified` with `(None, "")` so callers that only
    /// know the query name still work. Sweep dispatches (i221-A) reach
    /// for the qualified form so same-named queries across bluebooks
    /// can be disambiguated.
    pub fn resolve_query(&self, query_name: &str, attrs: &std::collections::HashMap<String, String>) -> serde_json::Value {
        self.resolve_query_qualified(None, "", query_name, attrs)
    }

    /// Gated read entry — the query-side mirror of `dispatch`. Runs the SAME
    /// before-gates as a command (authenticate / authorize PDP / service),
    /// keyed on the query name as the action, then calls `resolve_query` (the
    /// UNGATED core). Reads are authorized symmetrically with writes :
    /// `query`(gated) / `resolve_query`(ungated) parallels `dispatch` /
    /// `dispatch_impl`. The ungated core stays the inner path a service-gate's
    /// own check-query uses, so a gate never re-gates itself (no regress).
    /// `scope_to` row-scoping still narrows WHICH rows ; the gate decides
    /// WHETHER the read runs at all. The principal rides the reserved
    /// actor_kind/actor_auth_id keys, exactly as for a command.
    pub fn query(
        &mut self,
        query_name: &str,
        attrs: std::collections::HashMap<String, String>,
    ) -> Result<serde_json::Value, RuntimeError> {
        let mut gate_attrs: HashMap<String, Value> = HashMap::new();
        if let Some(k) = attrs.get(acl_readmodel::KIND_KEY) {
            gate_attrs.insert(acl_readmodel::KIND_KEY.to_string(), Value::Str(k.clone()));
        }
        if let Some(id) = attrs.get(acl_readmodel::AUTH_KEY) {
            gate_attrs.insert(acl_readmodel::AUTH_KEY.to_string(), Value::Str(id.clone()));
        }
        self.authorize_entry(query_name, &mut gate_attrs)?;
        Ok(self.resolve_query(query_name, &attrs))
    }

    /// Run interactively — the terminal adapter drives the runtime.
    #[cfg(not(target_arch = "wasm32"))]
    pub fn run_interactive(&mut self) {
        let name = self.domain.name.clone();
        adapter_terminal::run(self, &name);
    }
}

