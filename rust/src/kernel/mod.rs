//! Hand-written, domain-agnostic floor that every generated per-command function calls into.

pub mod attribute_shapes;
pub mod cli;
pub mod dispatch;
pub mod expr;
pub mod expression_operators;
pub mod json;
pub mod named_query;
pub mod needs;
pub mod orchestrate;
pub mod pattern;
pub mod query_ordering;
pub mod vocab;
// Kept at its old path so existing `refusal_wording::RefusalSite` call sites still resolve.
pub use vocab::refusal_template as refusal_wording;
pub mod read_model;
pub mod query_comparators;
pub mod reference_lookup;
pub mod repository;
pub mod routing;

pub use dispatch::{aggregate_step_site, apply_entity_command, decode_aggregate_arguments, decode_entity_arguments, dispatch, dispatch_entity, enforce_invariants, entity_step_site, ArgumentGates, EnsuresSpec, EntityInvariants, GivenSpec, Hydrate, InvariantSet, InvariantSpec, StepSite, TransitionCheck};
pub use expr::{interpret, BlockMode, Bound, Comparison, EvalContext, Expr, Field, Fielded, NoFields, Value, WithParent};
pub use json::Json;
pub use named_query::{QueryCondition, QueryConditionValue, QueryDef};
pub use orchestrate::{
    orchestrate, CompletedCompensation, CrossDomainPolicyRule, DispatchSpec, Handler, PendingCrossDomainReaction, PolicyRule, ProcessManagerDef,
    SagaInstance, Tables, WithValue, MAX_REACTION_DEPTH, REFUSED,
};
pub use reference_lookup::{
    command_deref, owner_deref, parent_deref, seeded_projections, DerefNode, ProjectedFieldSpec, ReferenceLookup, ReferenceSpec, ReferenceTable,
    SetProjectedField, WithReferences, DEREFERENCE_DEPTH,
};
pub use refusal_wording::RefusalSite;
pub use repository::{check_reference, check_role_via, filter_entries, holds_role_via, row_json, AggregateScan, InMemoryRepository, Repository};
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

/// Why a command dispatch was refused; each variant carries the refusal message.
///
/// Ruby's `UnknownVerb` has no variant: routing an unknown command name happens before dispatch.
/// `AbsentArgument` and `UnknownArgument` are raised only at the JSON boundary (`from_json`),
/// where the input has no static shape; typed args structs make them unconstructible afterwards.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Refusal {
    GivenNotMet(String),
    EnsuresNotMet(String),
    InvariantViolation(String),
    LifecycleRefused(String),
    AlreadyExists(String),
    NotFound(String),
    TypeMismatch(String),
    AbsentArgument(String),
    UnknownArgument(String),
    Unauthorized(String),
    Fault(String),
    /// `corrects` against a record that never emitted the corrected event.
    NothingToCorrect(String),
}

impl Refusal {
    /// The refusal class name, spelled as Ruby raises it; the semantics corpus compares it.
    pub fn kind(&self) -> &'static str {
        match self {
            Refusal::GivenNotMet(_) => "GivenNotMet",
            Refusal::EnsuresNotMet(_) => "EnsuresNotMet",
            Refusal::InvariantViolation(_) => "InvariantViolation",
            Refusal::LifecycleRefused(_) => "LifecycleRefused",
            Refusal::AlreadyExists(_) => "AlreadyExists",
            Refusal::NotFound(_) => "NotFound",
            Refusal::TypeMismatch(_) => "TypeMismatch",
            Refusal::AbsentArgument(_) => "AbsentArgument",
            Refusal::UnknownArgument(_) => "UnknownArgument",
            Refusal::Unauthorized(_) => "Unauthorized",
            Refusal::Fault(_) => "Fault",
            Refusal::NothingToCorrect(_) => "NothingToCorrect",
        }
    }
}

impl std::fmt::Display for Refusal {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Refusal::GivenNotMet(msg)
            | Refusal::EnsuresNotMet(msg)
            | Refusal::InvariantViolation(msg)
            | Refusal::LifecycleRefused(msg)
            | Refusal::AlreadyExists(msg)
            | Refusal::NotFound(msg)
            | Refusal::TypeMismatch(msg)
            | Refusal::AbsentArgument(msg)
            | Refusal::UnknownArgument(msg)
            | Refusal::Unauthorized(msg)
            | Refusal::Fault(msg)
            | Refusal::NothingToCorrect(msg) => write!(f, "{msg}"),
        }
    }
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
