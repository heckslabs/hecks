//! Why an expression or a dispatch was refused.

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
    pub const fn kind(&self) -> &'static str {
        match self {
            Self::GivenNotMet(_) => "GivenNotMet",
            Self::EnsuresNotMet(_) => "EnsuresNotMet",
            Self::InvariantViolation(_) => "InvariantViolation",
            Self::LifecycleRefused(_) => "LifecycleRefused",
            Self::AlreadyExists(_) => "AlreadyExists",
            Self::NotFound(_) => "NotFound",
            Self::TypeMismatch(_) => "TypeMismatch",
            Self::AbsentArgument(_) => "AbsentArgument",
            Self::UnknownArgument(_) => "UnknownArgument",
            Self::Unauthorized(_) => "Unauthorized",
            Self::Fault(_) => "Fault",
            Self::NothingToCorrect(_) => "NothingToCorrect",
        }
    }
}

impl std::fmt::Display for Refusal {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::GivenNotMet(msg)
            | Self::EnsuresNotMet(msg)
            | Self::InvariantViolation(msg)
            | Self::LifecycleRefused(msg)
            | Self::AlreadyExists(msg)
            | Self::NotFound(msg)
            | Self::TypeMismatch(msg)
            | Self::AbsentArgument(msg)
            | Self::UnknownArgument(msg)
            | Self::Unauthorized(msg)
            | Self::Fault(msg)
            | Self::NothingToCorrect(msg) => write!(f, "{msg}"),
        }
    }
}
