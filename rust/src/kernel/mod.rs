// HAND-WRITTEN, ON PURPOSE — the small floor every generated per-command
// function calls into. It knows nothing about Order, PizzaCreated, or any
// other domain-specific name; everything domain-specific lives in
// src/generated/, produced by bin/project_rust from canonical IR. Every
// fact below is cited against docs/guides/running-a-runtime.md and
// docs/guides/commands.md, not guessed or half-remembered from a prior
// read of the Ruby source.

pub mod cli;
pub mod dispatch;
pub mod expr;
pub mod json;
pub mod orchestrate;
pub mod repository;

pub use dispatch::{dispatch, dispatch_entity, EnsuresSpec, GivenSpec, Hydrate, TransitionCheck};
pub use expr::{interpret, Comparison, EvalContext, Expr, Field, Fielded, NoFields, Value};
pub use json::Json;
pub use orchestrate::{
    orchestrate, DispatchSpec, Handler, PolicyRule, ProcessManagerDef, SagaInstance, WithValue, MAX_REACTION_DEPTH, REFUSED,
};
pub use repository::{check_reference, InMemoryRepository, Repository};

#[derive(Debug, Clone)]
pub struct Event {
    pub name: String,
    pub aggregate: String,
    pub id: String,
    /// Mirrors Ruby's `payload: args` (running-a-runtime.md's "Commands: the
    /// roster and what each key means" section — `emits` is the plain list
    /// of event names a successful dispatch raises; the payload shape
    /// itself is `Runtime::CommandRules::Emission#emit`, read directly) —
    /// the dispatching command's own `args.to_json()`, structurally, not a
    /// debug-formatted string dump (that was this kernel's shape before
    /// policies/process managers needed to actually forward payload DATA
    /// into a re-triggered command's own `from_json`, not just print it).
    pub payload: json::Json,
    // NOT YET GENERATED: `occurred_at`. Ruby's Event carries a timestamp;
    // this kernel doesn't have a clock port yet, so it's left off rather
    // than faked with a wrong value. Flagged, not silently dropped.
}

/// The complete refusal roster for a command dispatch, per
/// docs/guides/commands.md's own table (quoted there as "the complete
/// roster" — not a subset picked for this slice). Two Ruby DOMAIN_REFUSALS
/// classes are deliberately NOT here: `Unauthorized` (role-mismatch — no
/// role-checking is generated yet) and `UnknownVerb` (dispatching a
/// command name that doesn't exist at all is a router-level concern, not
/// something one generated dispatch function raises about itself).
///
/// `AbsentArgument`/`UnknownArgument` ARE variants here, but only ever
/// raised at the JSON boundary (`from_json`, `rust/project/json_codec.rb`'s
/// `emit_unknown_argument_check`), never by a generated `dispatch_*`
/// function itself: a TYPED args struct still makes both structurally
/// impossible to construct once `from_json` has already succeeded — the
/// gap this refusal closes is that `from_json`'s own JSON input has no
/// static shape at all, exactly the reason Ruby needs a runtime check on
/// its own argument hash. `AbsentArgument` is mostly redundant with the
/// existing `v.require(...)` failures inside `from_json` (both refuse a
/// missing required field; this variant exists for a caller who wants to
/// distinguish "missing" from "wrong shape" by refusal KIND, not just
/// wording) — `UnknownArgument` is the one that closed a real gap: nothing
/// checked for an EXTRA key before this.
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
            | Refusal::UnknownArgument(msg) => write!(f, "{msg}"),
        }
    }
}

/// Mirrors `CommandInterpreter#call`'s own return shape: `[ctx.instance,
/// ctx.result]`, where `ctx.result` is built from `emit` — a record plus
/// whatever events actually fired, or a refusal with no record and no
/// events at all ("Refusals leave state untouched", commands.md's own
/// closing section).
pub type DispatchResult<T> = Result<(T, Vec<Event>), Refusal>;
