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

mod aggregate_state;
mod command_dispatch;
mod event_bus;
mod interpreter;
pub mod adapter_llm;
pub mod adapter_terminal;
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
pub use projection::Projection;
pub use repository::Repository;

use crate::ir::Domain;
use std::collections::HashMap;

pub struct Runtime {
    pub domain: Domain,
    pub repositories: HashMap<String, Repository>,
    pub event_bus: EventBus,
    pub policy_engine: PolicyEngine,
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
            repositories.insert(
                agg.name.clone(),
                Repository::new(&agg.name, data_dir.clone()),
            );
        }

        let mut policy_engine = PolicyEngine::new();
        for policy in &domain.policies {
            policy_engine.register(&policy.name, &policy.on_event, &policy.trigger_command);
        }

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
        self.repositories
            .get(aggregate_name)
            .and_then(|repo| repo.find(id))
    }

    pub fn all(&self, aggregate_name: &str) -> Vec<&AggregateState> {
        self.repositories
            .get(aggregate_name)
            .map(|repo| repo.all())
            .unwrap_or_default()
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
            let triggers = self.policy_engine.react(event);
            for trigger in triggers {
                let policy_name = trigger.policy_name.clone();
                let cmd = trigger.command_name.clone();
                let mut data = trigger.event_data.clone();

                if let Some(self_ref) = self.find_self_ref_for(&cmd, &event.aggregate_type) {
                    if !data.contains_key(&self_ref) {
                        data.insert(self_ref, Value::Str(event.aggregate_id.clone()));
                    }
                }

                if let Ok(inner_result) = command_dispatch::dispatch(self, &cmd, data) {
                    self.drain_policies(&inner_result);
                }
                self.policy_engine.complete(&policy_name);
            }
        }
    }

    /// If `cmd_name` is on the aggregate type `upstream_type` and has
    /// a reference whose target matches that aggregate's own name
    /// (self-ref), return the reference's name (honoring `as:` aliases).
    /// Mirrors `command_dispatch::find_self_ref` but is callable from
    /// outside dispatch — drain_policies needs to know the kwarg name
    /// to inject the upstream id under.
    fn find_self_ref_for(&self, cmd_name: &str, upstream_type: &str) -> Option<String> {
        for agg in &self.domain.aggregates {
            if agg.name != upstream_type { continue; }
            for cmd in &agg.commands {
                if cmd.name != cmd_name { continue; }
                let agg_snake = to_snake(&agg.name);
                for r in &cmd.references {
                    let ref_snake = to_snake(&r.target);
                    if ref_snake == agg_snake || agg_snake.ends_with(&ref_snake) {
                        return Some(r.name.clone());
                    }
                }
            }
        }
        None
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
    pub fn resolve_query(&self, query_name: &str, attrs: &std::collections::HashMap<String, String>) -> serde_json::Value {
        let agg_name = self.domain.aggregates.iter()
            .find(|a| a.queries.iter().any(|q| q.name == query_name))
            .map(|a| a.name.clone())
            .unwrap_or_default();

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

        // Generic query: return aggregate state
        let state = self.all(&agg_name);
        let records: Vec<serde_json::Value> = state.iter().map(|s| {
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

fn to_snake(s: &str) -> String {
    let mut out = String::new();
    for (i, c) in s.chars().enumerate() {
        if c.is_uppercase() && i > 0 { out.push('_'); }
        out.push(c.to_lowercase().next().unwrap_or(c));
    }
    out
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
