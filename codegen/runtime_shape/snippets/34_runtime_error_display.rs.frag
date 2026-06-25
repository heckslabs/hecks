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

