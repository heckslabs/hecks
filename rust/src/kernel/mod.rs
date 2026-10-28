//! Hand-written, domain-agnostic floor that every generated per-command function calls into.

pub mod cli;
pub mod collecting;
pub mod dispatch;
pub mod json;
pub mod named_query;
pub mod needs;
pub mod orchestrate;
pub mod pattern;
pub mod present;
pub mod query_cursor;
pub mod query_ordering;
pub mod vocab;
// Kept at its old path so existing `refusal_wording::RefusalSite` call sites still resolve.
pub use vocab::refusal_template as refusal_wording;
pub mod query_comparators;
pub mod read_model;
pub mod reference_lookup;
pub mod repository;
pub mod routing;

pub use dispatch::{
    aggregate_step_site, apply_entity_command, decode_aggregate_arguments, decode_entity_arguments,
    dispatch, dispatch_entity, enforce_invariants, entity_step_site, ArgumentGates, EnsuresSpec,
    EntityInvariants, GivenSpec, Hydrate, InvariantSet, InvariantSpec, StepSite, TransitionCheck,
};
pub use expr::{
    interpret, BlockMode, Bound, Comparison, EvalContext, Expr, Field, Fielded, NoFields,
    StripSide, Value, WithParent,
};
pub use json::Json;
// The expression evaluator, its operators and the refusal type are their own crate, shared with
// the host; the kernel re-exports them so every `crate::kernel::expr::…` path keeps working.
pub use hecks_expr::{attribute_shapes, expr, expression_operators, ruby_float, Refusal};
pub use named_query::{QueryCondition, QueryConditionValue, QueryDef};
pub use orchestrate::{
    orchestrate, CompletedCompensation, CrossDomainPolicyRule, DispatchSpec, Handler,
    PendingCrossDomainReaction, PolicyRule, ProcessManagerDef, SagaInstance, Tables, WithValue,
    MAX_REACTION_DEPTH, REFUSED,
};
pub use reference_lookup::{
    command_deref, owner_deref, parent_deref, seeded_projections, DerefNode, ProjectedFieldSpec,
    ReferenceLookup, ReferenceSpec, ReferenceTable, SetProjectedField, WithReferences,
    DEREFERENCE_DEPTH,
};
pub use refusal_wording::RefusalSite;
pub use repository::{
    check_reference, check_role_via, check_roles_via, filter_entries, holds_role_via, row_json,
    AggregateScan, InMemoryRepository, Repository,
};
pub use routing::{CommandInvocation, RoutingEnvelope};

/// A domain event raised by a successful command dispatch.
#[derive(Debug, Clone)]
pub struct Event {
    pub name: String,
    pub aggregate: String,
    pub id: String,
    /// The dispatching command's arguments as structured JSON.
    pub payload: json::Json,
    /// Wall-clock timestamp resolved by the host; the kernel has no clock, to stay deterministic.
    /// Every event from one top-level step, cascading reactions included, gets the same value.
    /// `None` until `orchestrate` stamps it, and for callers that never supply one.
    pub occurred_at: Option<String>,
    /// Runtime-only saga bookkeeping, never serialized. Stamped by `orchestrate` when a saga leg
    /// causes the event, so an unrelated saga correlating on another field cannot claim it.
    pub correlation: Option<std::collections::HashMap<String, String>>,
}

/// The saved record plus the events it raised, or a refusal that leaves state untouched.
pub type DispatchResult<T> = Result<(T, Vec<Event>), Refusal>;

/// One aggregate record saved by a dispatch, reported so a host can journal per aggregate.
///
/// `operation` is always `"save"`: no dispatch path deletes.
#[derive(Debug, Clone)]
pub struct MutationRecord {
    pub aggregate: String,
    pub id: String,
    pub operation: &'static str,
    pub state: Json,
}

/// Lets `dispatch`/`dispatch_entity`, generic over the record type, call a record's `to_json()`.
pub trait ToJson {
    fn to_json(&self) -> Json;
}
