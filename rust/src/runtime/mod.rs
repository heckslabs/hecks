//! Hecks Runtime — executes domains from IR
//!
//! Dispatches commands, enforces givens, applies mutations,
//! emits events, triggers policies, updates projections.
//! The beating heart.
//!
//! Usage:
//!   let domain = parser::parse(&source);
//!   let mut rt = Runtime::boot(domain);
//!   let result = rt.dispatch("CreatePizza", attrs! { "name" => "Margherita" });
//!
//! [antibody-exempt: rust/src/runtime/mod.rs — kernel-floor runtime.
//!  i156 added the AmbiguousCommand variant for strict bare-name
//!  dispatch ; the rest is pre-i156.]

mod aggregate_state;
mod command_dispatch;
mod event_bus;
pub mod pm_engine;
mod interpreter;
pub mod adapter_io;
pub mod adapter_llm;
pub mod adapter_registry;
pub mod adapter_terminal;
pub mod shell_dispatcher;
mod lifecycle;
mod middleware;
mod policy_engine;
mod projection;
mod repository;
pub mod seed_loader;

pub use aggregate_state::AggregateState;
pub use command_dispatch::CommandResult;
pub use event_bus::{Event, EventBus};
pub use middleware::{CommandContext, MiddlewareStack, Phase};
pub use policy_engine::{PolicyEngine, PolicyTrigger};
pub use pm_engine::{PMBinding, PMEngine, PMInstanceState, PMTrigger};
pub use projection::Projection;
pub use repository::Repository;

use crate::ir::Domain;
use std::collections::HashMap;

pub struct Runtime {
    pub domain: Domain,
    pub repositories: HashMap<String, Repository>,
    pub event_bus: EventBus,
    pub policy_engine: PolicyEngine,
    pub pm_engine: PMEngine,
    pub projections: Vec<Projection>,
    pub middleware: MiddlewareStack,
    pub data_dir: Option<String>,
}

impl Runtime {
    pub fn boot(domain: Domain) -> Self {
        Self::boot_with_data_dir(domain, None)
    }

    pub fn boot_with_data_dir(domain: Domain, data_dir: Option<String>) -> Self {
        let mut repositories = HashMap::new();
        for agg in &domain.aggregates {
            // i142 Tier 2 — key repositories by (context, name) so
            // same-name aggregates in different contexts get distinct
            // Repository instances (and distinct heki paths).
            let key = repo_key(agg.context.as_deref(), &agg.name);
            repositories.insert(
                key,
                Repository::new_with_context(
                    &agg.name,
                    data_dir.clone(),
                    agg.identified_by.clone(),
                    agg.context.clone(),
                ),
            );
        }

        let mut policy_engine = PolicyEngine::new();
        for policy in &domain.policies {
            policy_engine.register(&policy.name, &policy.on_event, &policy.trigger_command);
        }

        let mut pm_engine = PMEngine::new();
        for pm in &domain.process_managers {
            pm_engine.register(pm);
        }
        // Phase D — load persisted PM instances from heki so transitions
        // resume across hecks-life subprocess forks (production daemons
        // fork per dispatch ; without this, in-memory state evaporates
        // and PMs effectively don't accumulate).
        pm_engine.load_persisted(data_dir.as_deref());

        let projections = domain
            .aggregates
            .iter()
            .map(|agg| projection::auto_projection(&agg.name))
            .collect();

        Runtime {
            domain,
            repositories,
            event_bus: EventBus::new(),
            policy_engine,
            pm_engine,
            projections,
            middleware: MiddlewareStack::new(),
            data_dir,
        }
    }

    pub fn dispatch(
        &mut self,
        command_name: &str,
        attrs: HashMap<String, Value>,
    ) -> Result<CommandResult, RuntimeError> {
        // Middleware: before
        let ctx = CommandContext {
            command_name: command_name.to_string(),
            attrs: attrs.clone(),
            result: None,
        };
        self.middleware.run_before(&ctx);

        // Core dispatch
        let result = command_dispatch::dispatch(self, command_name, attrs)?;

        // Breadcrumb : write the entry-point command (the top-level
        // dispatch the user / CLI invoked) to a tiny plaintext file
        // under data_dir. The statusline reads it.
        //
        // Two filters keep the statusline glyph showing what's actually
        // INTERESTING, not the constant body-daemon traffic :
        //
        //   1. Top-level only — `drain_policies`'s cascade calls go
        //      through `command_dispatch::dispatch` directly and don't
        //      touch the breadcrumb. Without this, the cascade leaf
        //      (Synapse.DecaySynapse / Awareness.RecordMoment / Mode.
        //      SetAttentive) drowned the entry-point variety.
        //
        //   2. Non-daemon only — when HECKS_DAEMON=1 is set in the
        //      environment, the dispatch is body-cycle plumbing
        //      (mindstream.sh, pulse_organs.sh, heart/breath loops)
        //      and the breadcrumb is suppressed. The statusline glyph
        //      then only updates when a HUMAN-driven dispatch fires
        //      (Antibody.RegisterExemption from the prompt, Mood.
        //      Express, etc.) — exactly the "what are we working on"
        //      signal the bar is for.
        let is_daemon = std::env::var("HECKS_DAEMON").ok().as_deref() == Some("1");
        if !is_daemon {
            if let Some(ref dir) = self.data_dir {
                let now = std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map(|d| d.as_secs()).unwrap_or(0);
                let path = format!("{}/.last_dispatch", dir.trim_end_matches('/'));
                let _ = std::fs::write(&path,
                    format!("{}.{}\n{}\n", result.aggregate_type, command_name, now));
            }
        }

        // Middleware: after
        let ctx = CommandContext {
            command_name: command_name.to_string(),
            attrs: ctx.attrs,
            result: Some(CommandResult {
                aggregate_id: result.aggregate_id.clone(),
                aggregate_type: result.aggregate_type.clone(),
                event: result.event.clone(),
            }),
        };
        self.middleware.run_after(&ctx);

        // Update projections
        if let Some(ref event) = result.event {
            for proj in &mut self.projections {
                proj.apply(event);
            }
        }

        // Drain policy triggers — recursively, so chains cascade fully
        self.drain_policies(&result);

        Ok(result)
    }

    /// Dispatch without firing policy cascades. Used by tests for
    /// SETUP commands so they don't overshoot the test command's
    /// required state. The test command itself dispatches via the
    /// regular `dispatch` so its emit cascade can fire and be
    /// asserted via `expect emits: [...]`.
    pub fn dispatch_isolated(
        &mut self,
        command_name: &str,
        attrs: HashMap<String, Value>,
    ) -> Result<CommandResult, RuntimeError> {
        let result = command_dispatch::dispatch(self, command_name, attrs)?;
        if let Some(ref event) = result.event {
            for proj in &mut self.projections {
                proj.apply(event);
            }
        }
        Ok(result)
    }

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

    /// Drain policy triggers recursively — each triggered command
    /// can emit events that trigger more policies. This is how
    /// EnterSleep cascades through 8 dream cycles to WakeUp.
    ///
    /// When the triggered command has a self-reference to the same
    /// aggregate the event came from, inject the upstream aggregate_id
    /// under that ref's name. Without this, downstream cascades stop
    /// at any self-ref command (the dispatch errors with missing
    /// self-referencing id), leaving aggregates stuck mid-pipeline.
    /// The behaviors generator's static cascade prediction
    /// (cascade::cascade_emits) assumes the runtime honors these
    /// triggers — so this injection is what makes the prediction true.
    fn drain_policies(&mut self, result: &CommandResult) {
        if let Some(ref event) = result.event {
            // Drive process_managers + dispatch their declared commands.
            // Each PMTrigger carries dispatches: Vec<String> populated
            // from the handler's declarative `dispatch "..."` lines ;
            // route through cascade dispatcher so policies + nested PMs
            // + downstream emits all fire normally.
            let pm_triggers = self.pm_engine.react(event);
            for t in pm_triggers.clone() {
                // Phase D — persist the new instance state immediately
                // after each transition so the next subprocess fork sees
                // it. Best-effort : a failed write doesn't abort the
                // cascade ; the audit trail captures it via heki's
                // dispatch context.
                let _ = self.pm_engine.persist_instance(
                    &t.pm_name,
                    &t.correlation_id,
                    self.data_dir.as_deref(),
                );

                for dispatched in &t.dispatches {
                    let mut data = std::collections::HashMap::new();
                    self.inject_refs(
                        dispatched,
                        &event.aggregate_type,
                        &event.aggregate_id,
                        &mut data,
                    );
                    let inner = command_dispatch::dispatch_cascade(
                        self,
                        dispatched,
                        data,
                        &event.aggregate_type,
                        &event.aggregate_id,
                    );
                    if let Ok(inner_result) = inner {
                        self.drain_policies(&inner_result);
                    }
                }
                self.pm_engine.complete(&t.pm_name);
            }

            let triggers = self.policy_engine.react(event);
            for trigger in triggers {
                let policy_name = trigger.policy_name.clone();
                let cmd = trigger.command_name.clone();
                let mut data = trigger.event_data.clone();

                // Inject every reference the triggered command needs:
                //   1. self-ref or upstream-ref → use upstream event's aggregate_id
                //   2. other refs → use any record currently in that repo (singleton)
                // This makes static cascade prediction work across aggregate
                // boundaries: a policy chain can hop A→B→C even when neither
                // B nor C's input attrs were in the original test command.
                self.inject_refs(&cmd, &event.aggregate_type, &event.aggregate_id, &mut data);

                // i111-K — pass the upstream type+id as a cascade hint.
                // When the triggered command's aggregate matches
                // upstream_type AND a record exists at upstream_id, the
                // cascade preserves the id rather than counter-minting
                // a fresh one. This closes the i111-C surprise where
                // multi-step pipeline roots had to declare
                // `identified_by` just to keep gated cascades landing
                // on the same row. Cross-type cascades (A → B) and
                // cases without an existing record fall through to
                // standard resolution unchanged.
                let inner = command_dispatch::dispatch_cascade(
                    self, &cmd, data,
                    &event.aggregate_type, &event.aggregate_id,
                );
                if let Ok(inner_result) = inner {
                    self.drain_policies(&inner_result);
                }
                self.policy_engine.complete(&policy_name);
            }
        }
    }

    /// For each reference on the triggered command, inject an id under its
    /// kwarg name if not already present:
    ///   - target matches upstream event's aggregate type → use event's id
    ///   - target is the command's own aggregate (self-ref) and a record
    ///     exists in that repo → use the existing record's id
    ///   - target is any other aggregate with an existing record (singleton
    ///     pattern) → use that record's id
    /// The bluebook stays reference-only; the runtime resolves to ids.
    fn inject_refs(
        &self,
        cmd_name: &str,
        upstream_type: &str,
        upstream_id: &str,
        data: &mut HashMap<String, Value>,
    ) {
        for agg in &self.domain.aggregates {
            for cmd in &agg.commands {
                if cmd.name != cmd_name { continue; }
                for r in &cmd.references {
                    if data.contains_key(&r.name) { continue; }
                    if r.target == upstream_type {
                        data.insert(r.name.clone(), Value::Str(upstream_id.to_string()));
                        continue;
                    }
                    // Singleton fallback: pick any existing record of the
                    // ref's target type. References don't carry context ;
                    // resolve target's context by scanning the loaded
                    // domain (i142 Tier 2). True cross-context refs land
                    // in Tier 3.
                    //
                    // i161 — when the same aggregate name lives in
                    // multiple contexts (e.g. Mind.Musing + Musings.Musing
                    // post-i117 R4), the naive `find()` returns the first
                    // by depth-then-path iteration order, so the wrong
                    // context wins and singleton fallback hits the wrong
                    // repo. The dispatching command is on `agg` ; prefer
                    // a target in the SAME context, fall back to first
                    // match for genuine cross-context refs. Self-refs
                    // (r.target == agg.name) resolve trivially via
                    // agg.context — no domain scan needed.
                    let target_ctx = if r.target == agg.name {
                        agg.context.as_deref()
                    } else {
                        self.domain.aggregates.iter()
                            .find(|a| a.name == r.target && a.context == agg.context)
                            .or_else(|| self.domain.aggregates.iter().find(|a| a.name == r.target))
                            .and_then(|a| a.context.as_deref())
                    };
                    let key = repo_key(target_ctx, &r.target);
                    if let Some(repo) = self.repositories.get(&key) {
                        if let Some(existing) = repo.all().first() {
                            data.insert(r.name.clone(), Value::Str(existing.id.clone()));
                        }
                    }
                }
                // Inject the identity field when the triggered command's
                // aggregate uses identified_by. Two cases this catches:
                //   1. Key absent — policy cascade didn't supply an id.
                //   2. Key present but value doesn't match any record —
                //      upstream aggregate leaked its own identified_by field
                //      (e.g. Pulse's `name="pulse"` in a BodyPulse event) into
                //      the cascade data, pointing at a non-existent record.
                // The injection picks the lexicographically lowest existing
                // record id (deterministic). For natural-key singletons
                // (Heartbeat → "heartbeat", Tick → "tick"), this finds the
                // canonical row even when junk counter-minted records sit
                // alongside it. Without this, every cascade tick creates yet
                // another counter-minted record because id_for_command
                // honored the leaked upstream value.
                if let Some(ref key) = agg.identified_by {
                    let agg_key = repo_key(agg.context.as_deref(), &agg.name);
                    if let Some(repo) = self.repositories.get(&agg_key) {
                        let needs_inject = match data.get(key.as_str()) {
                            None => true,
                            Some(v) => v.as_str()
                                .map(|s| repo.find(s).is_none())
                                .unwrap_or(true),
                        };
                        if needs_inject {
                            // Prefer a record whose id is non-numeric (the
                            // natural-key form, e.g. "heartbeat") over a
                            // counter-minted u64 id ("1", "42", "302" — the
                            // junk left by pre-i80 dispatches). Within each
                            // group fall back to lex-min for determinism.
                            let pick = repo.all().iter()
                                .map(|s| s.id.clone())
                                .min_by(|a, b| {
                                    let an = a.chars().all(|c| c.is_ascii_digit());
                                    let bn = b.chars().all(|c| c.is_ascii_digit());
                                    an.cmp(&bn).then_with(|| a.cmp(b))
                                });
                            if let Some(id) = pick {
                                data.insert(key.clone(), Value::Str(id));
                            } else {
                                // Empty repo + leaked upstream key (i151) —
                                // remove the leaked id so id_for_command
                                // counter-mints a fresh id rather than
                                // creating a record named after the upstream
                                // aggregate (e.g. heartbeat with id="tick"
                                // because Tick.MindstreamTick's name="tick"
                                // leaked through Ticked → Pulse.Emit →
                                // BodyPulse → AccumulateFatigue). Without
                                // this, every singleton aggregate downstream
                                // of a named-key emitter inherits the wrong
                                // identifier on first dispatch and silently
                                // accumulates orphans in subsequent ticks.
                                data.remove(key.as_str());
                            }
                        }
                    }
                }
                return; // first matching command wins
            }
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
    pub fn resolve_query(&self, query_name: &str, attrs: &std::collections::HashMap<String, String>) -> serde_json::Value {
        let (agg_name, query_ir) = self.domain.aggregates.iter()
            .find_map(|a| a.queries.iter().find(|q| q.name == query_name).map(|q| (a.name.clone(), q.clone())))
            .unwrap_or_else(|| (String::new(), crate::ir::Query {
                name: query_name.to_string(),
                description: None,
                attributes: vec![],
                wheres: vec![],
                order_by: None,
                limit: None,
            }));

        // MatchInput: search loaded commands by phrase
        if query_name == "MatchInput" {
            let input = attrs.get("input").map(|s| s.to_lowercase()).unwrap_or_default();
            let mut best_phrase = String::new();
            let mut best_agg = String::new();
            let mut best_cmd = String::new();
            let mut best_score: f64 = 0.0;
            for agg in &self.domain.aggregates {
                for cmd in &agg.commands {
                    let phrase = pascal_to_phrase(&cmd.name);
                    let score = trigram_sim(&input, &phrase);
                    if score > best_score {
                        best_score = score;
                        best_phrase = phrase;
                        best_agg = agg.name.clone();
                        best_cmd = cmd.name.clone();
                    }
                }
            }
            return serde_json::json!({
                "aggregate": agg_name, "query": query_name,
                "state": {
                    "match": if best_score > 0.3 { "found" } else { "none" },
                    "phrase": best_phrase, "aggregate": best_agg,
                    "command": best_cmd,
                    "confidence": format!("{:.0}", best_score * 100.0),
                }
            });
        }

        // Generic query: walk repo.all(), apply wheres / order_by / limit.
        let state = self.all(&agg_name);
        let mut filtered: Vec<&AggregateState> = state.into_iter()
            .filter(|s| query_ir.wheres.iter().all(|w| where_matches(s, w, attrs)))
            .collect();

        if let Some(ref ob) = query_ir.order_by {
            filtered.sort_by(|a, b| {
                let av = a.fields.get(&ob.field).map(|v| v.to_string()).unwrap_or_default();
                let bv = b.fields.get(&ob.field).map(|v| v.to_string()).unwrap_or_default();
                match ob.direction {
                    crate::ir::Direction::Asc  => av.cmp(&bv),
                    crate::ir::Direction::Desc => bv.cmp(&av),
                }
            });
        }

        if let Some(ref ls) = query_ir.limit {
            let cap = resolve_limit_value(&ls.value, attrs);
            if let Some(n) = cap {
                filtered.truncate(n);
            }
        }

        let records: Vec<serde_json::Value> = filtered.iter().map(|s| {
            let mut map = serde_json::Map::new();
            for (k, v) in &s.fields {
                map.insert(k.clone(), match v {
                    Value::Str(s) => serde_json::json!(s),
                    Value::Int(n) => serde_json::json!(n),
                    Value::Bool(b) => serde_json::json!(b),
                    _ => serde_json::json!(v.to_string()),
                });
            }
            serde_json::Value::Object(map)
        }).collect();
        serde_json::json!({
            "aggregate": agg_name, "query": query_name,
            "state": if records.len() == 1 { records[0].clone() } else { serde_json::json!(records) },
        })
    }

    /// Run interactively — the terminal adapter drives the runtime.
    pub fn run_interactive(&mut self) {
        let name = self.domain.name.clone();
        adapter_terminal::run(self, &name);
    }
}

/// Dynamic value — aggregates are bags of these
#[derive(Debug, Clone, PartialEq)]
pub enum Value {
    Str(String),
    Int(i64),
    Bool(bool),
    List(Vec<Value>),
    Map(HashMap<String, Value>),
    Null,
}

impl Value {
    pub fn as_str(&self) -> Option<&str> {
        match self {
            Value::Str(s) => Some(s),
            _ => None,
        }
    }

    pub fn as_int(&self) -> Option<i64> {
        match self {
            Value::Int(n) => Some(*n),
            _ => None,
        }
    }

    pub fn as_bool(&self) -> Option<bool> {
        match self {
            Value::Bool(b) => Some(*b),
            _ => None,
        }
    }

    pub fn as_list(&self) -> Option<&Vec<Value>> {
        match self {
            Value::List(v) => Some(v),
            _ => None,
        }
    }
}

impl std::fmt::Display for Value {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Value::Str(s) => write!(f, "{}", s),
            Value::Int(n) => write!(f, "{}", n),
            Value::Bool(b) => write!(f, "{}", b),
            Value::List(v) => write!(f, "[{} items]", v.len()),
            Value::Map(m) => write!(f, "{{{} fields}}", m.len()),
            Value::Null => write!(f, "null"),
        }
    }
}

#[derive(Debug)]
pub enum RuntimeError {
    UnknownCommand(String),
    UnknownAggregate(String),
    GivenFailed { message: String, expression: String },
    AggregateNotFound(String),
    MissingAttribute(String),
    LifecycleViolation {
        command: String,
        field: String,
        current: String,
        allowed: Vec<String>,
    },
    /// i156 — bare-name dispatch resolved to multiple aggregates when
    /// `HECKS_STRICT_DISPATCH=1` is set. The validator_corpus
    /// `bare_name_collisions` rule flags these statically ; this is
    /// the runtime-side enforcement for callers that haven't
    /// migrated.
    AmbiguousCommand {
        name: String,
        candidates: Vec<String>,
    },
}

impl std::fmt::Display for RuntimeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            RuntimeError::UnknownCommand(c) => write!(f, "unknown command: {}", c),
            RuntimeError::UnknownAggregate(a) => write!(f, "unknown aggregate: {}", a),
            RuntimeError::GivenFailed { message, .. } => write!(f, "given failed: {}", message),
            RuntimeError::AggregateNotFound(id) => write!(f, "aggregate not found: {}", id),
            RuntimeError::MissingAttribute(a) => write!(f, "missing attribute: {}", a),
            RuntimeError::LifecycleViolation { command, field, current, allowed } => {
                write!(f, "lifecycle violation: {} cannot run when {} is '{}' (allowed from: {:?})",
                    command, field, current, allowed)
            }
            RuntimeError::AmbiguousCommand { name, candidates } => {
                write!(f, "ambiguous bare-name dispatch: '{}' is declared on aggregates {:?} — qualify with `Aggregate.{}`",
                    name, candidates, name)
            }
        }
    }
}

/// Macro for building attribute maps
#[macro_export]
macro_rules! attrs {
    ($($key:expr => $val:expr),* $(,)?) => {{
        let mut map = std::collections::HashMap::new();
        $(map.insert($key.to_string(), $val);)*
        map
    }};
}

/// i142 Tier 2 — compose the HashMap key for a repository.
/// Same-name aggregates in different bounded contexts get distinct
/// keys ("Library::Inbox" vs "Workshop::Inbox") so they end up with
/// distinct Repository instances and distinct .heki paths.
/// Legacy aggregates without a context use their bare name.
pub fn repo_key(context: Option<&str>, name: &str) -> String {
    match context {
        Some(ctx) => format!("{}::{}", ctx, name),
        None => name.to_string(),
    }
}

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

/// i101 — apply one WhereClause to one record. Resolves kwarg-refs
/// (`":author"`) against the dispatch attrs ; literal values match
/// the record's field as a string. Returns true when the record
/// matches the clause, false otherwise.
fn where_matches(
    state: &AggregateState,
    clause: &crate::ir::WhereClause,
    attrs: &std::collections::HashMap<String, String>,
) -> bool {
    let target = resolve_where_value(&clause.value, attrs);
    let actual = state.fields.get(&clause.field).map(|v| v.to_string()).unwrap_or_default();
    match clause.op {
        crate::ir::WhereOp::Eq  => actual == target,
        crate::ir::WhereOp::Ne  => actual != target,
        crate::ir::WhereOp::Gt  => compare_strings(&actual, &target).is_gt(),
        crate::ir::WhereOp::Gte => !compare_strings(&actual, &target).is_lt(),
        crate::ir::WhereOp::Lt  => compare_strings(&actual, &target).is_lt(),
        crate::ir::WhereOp::Lte => !compare_strings(&actual, &target).is_gt(),
    }
}

/// Numeric ordering when both sides parse as i64 ; lexical otherwise.
/// Keeps the runtime executor honest for both string-typed status
/// fields and numeric-typed counters.
fn compare_strings(a: &str, b: &str) -> std::cmp::Ordering {
    if let (Ok(an), Ok(bn)) = (a.parse::<i64>(), b.parse::<i64>()) {
        return an.cmp(&bn);
    }
    a.cmp(b)
}

/// Resolve a where-clause value : `:foo` reads `attrs["foo"]` (kwarg-ref) ;
/// any other token is a literal returned as-is.
fn resolve_where_value(
    value: &str,
    attrs: &std::collections::HashMap<String, String>,
) -> String {
    if let Some(kwarg) = value.strip_prefix(':') {
        return attrs.get(kwarg).cloned().unwrap_or_default();
    }
    value.to_string()
}

/// Resolve a limit value : `:foo` reads `attrs["foo"]` and parses as
/// usize ; numeric token parses directly. Returns None when the source
/// can't be parsed (so the executor leaves the result un-truncated).
fn resolve_limit_value(
    value: &str,
    attrs: &std::collections::HashMap<String, String>,
) -> Option<usize> {
    if let Some(kwarg) = value.strip_prefix(':') {
        return attrs.get(kwarg).and_then(|s| s.parse::<usize>().ok());
    }
    value.parse::<usize>().ok()
}

fn pascal_to_phrase(name: &str) -> String {
    let mut result = String::new();
    for (i, c) in name.chars().enumerate() {
        if i > 0 && c.is_uppercase() { result.push(' '); }
        result.push(c.to_lowercase().next().unwrap_or(c));
    }
    result
}

fn trigram_sim(a: &str, b: &str) -> f64 {
    if a == b { return 1.0; }
    let a_t: Vec<String> = a.chars().collect::<Vec<_>>().windows(3).map(|w| w.iter().collect()).collect();
    let b_t: Vec<String> = b.chars().collect::<Vec<_>>().windows(3).map(|w| w.iter().collect()).collect();
    if a_t.is_empty() || b_t.is_empty() { return 0.0; }
    let matches = a_t.iter().filter(|t| b_t.contains(t)).count();
    (2.0 * matches as f64) / (a_t.len() + b_t.len()) as f64
}
