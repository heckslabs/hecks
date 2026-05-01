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

