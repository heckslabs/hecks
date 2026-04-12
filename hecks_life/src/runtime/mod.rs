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
mod lifecycle;
mod middleware;
pub mod persistence;
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

        // Drain policy triggers
        if let Some(ref event) = result.event {
            let triggers = self.policy_engine.react(event);
            for trigger in triggers {
                let policy_name = trigger.policy_name.clone();
                let cmd = trigger.command_name.clone();
                let data = trigger.event_data.clone();

                let _ = command_dispatch::dispatch(self, &cmd, data);
                self.policy_engine.complete(&policy_name);
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
