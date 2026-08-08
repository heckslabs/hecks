// HAND-WRITTEN, ON PURPOSE — the small floor every generated per-command
// function calls into. It knows nothing about Order, PizzaCreated, or any
// other domain-specific name; everything domain-specific lives in
// src/generated/, produced by bin/project_rust from canonical IR. Every
// fact below is cited against docs/guides/running-a-runtime.md and
// docs/guides/commands.md, not guessed or half-remembered from a prior
// read of the Ruby source.

pub mod dispatch;
pub mod expr;
pub mod repository;

pub use dispatch::{dispatch, EnsuresSpec, GivenSpec, Hydrate, TransitionCheck};
pub use expr::{interpret, Comparison, EvalContext, Expr, Field, Fielded, NoFields, Value};
pub use repository::{InMemoryRepository, Repository};

#[derive(Debug, Clone)]
pub struct Event {
    pub name: String,
    pub aggregate: String,
    pub id: String,
    /// Mirrors Ruby's `payload: args` (running-a-runtime.md's "Commands: the
    /// roster and what each key means" section — `emits` is the plain list
    /// of event names a successful dispatch raises; the payload shape
    /// itself is `Runtime::CommandRules::Emission#emit`, read directly).
    pub payload: std::collections::BTreeMap<String, String>,
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
/// `AbsentArgument` and `UnknownArgument` are ALSO not variants here, and
/// that's not an oversight: a generated Rust args struct (e.g.
/// `CreatePizzaArgs`) makes both structurally impossible at compile time
/// — you cannot construct one missing a required field or carrying an
/// extra one. Ruby needs a runtime check because its argument hash has no
/// static shape; Rust's type system already closes that gate. A real
/// architectural difference, not a gap.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Refusal {
    GivenNotMet(String),
    EnsuresNotMet(String),
    InvariantViolation(String),
    LifecycleRefused(String),
    AlreadyExists(String),
    NotFound(String),
    TypeMismatch(String),
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
            | Refusal::TypeMismatch(msg) => write!(f, "{msg}"),
        }
    }
}

/// Mirrors `CommandInterpreter#call`'s own return shape: `[ctx.instance,
/// ctx.result]`, where `ctx.result` is built from `emit` — a record plus
/// whatever events actually fired, or a refusal with no record and no
/// events at all ("Refusals leave state untouched", commands.md's own
/// closing section).
pub type DispatchResult<T> = Result<(T, Vec<Event>), Refusal>;
