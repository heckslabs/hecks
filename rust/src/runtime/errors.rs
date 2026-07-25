//! errors — the runtime error surface. RuntimeError (every refusal the
//! dispatch path can return — unknown verb/aggregate, given refused,
//! authorization denied, persistence refused, …) and its operator-facing
//! Display. The type travels WITH its impls (file-header standard) ; nothing
//! else lives here.
//!
//! Cask extracted VERBATIM from runtime/mod.rs (shrink-mod phase B, wave 1).
//!
//! [antibody-exempt: rust/src/runtime/errors.rs — pure-utility error types
//!  (no domain), relocated verbatim from mod.rs blanket.]


#[derive(Debug)]
pub enum RuntimeError {
    UnknownCommand(String),
    UnknownAggregate(String),
    /// i735 defect 2 — a dispatch targeted an aggregate whose wired
    /// `:sqlite` adapter failed to build at boot (the table could not be
    /// created / the db could not be opened). The runtime refused that
    /// aggregate's persistence rather than panicking or silently swapping
    /// to heki ; the message carries the loud reason recorded at boot.
    PersistenceRefused(String),
    GivenFailed { message: String, expression: String },
    /// f4 — an aggregate-level invariant's `holds_when` predicate was false
    /// on the resulting state after a command's mutations. The command is
    /// rejected with 0 events, the same shape as a failed `given`. `name`
    /// is the invariant's rule name ; `expression` is its predicate source.
    InvariantViolation { name: String, expression: String },
    /// Payload gate (ACL, 2026-07-18) — a VALUE-OBJECT invariant was false
    /// for an incoming command attribute, judged BEFORE hydration or
    /// mutation. Refused at the door : no state touch, no event, no
    /// cascade. `field` names the offending command attribute so forms
    /// can ring the exact input ; `value` is what the caller sent.
    PayloadInvariantViolation { name: String, expression: String, field: String, value: String },
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
    /// deciderate Inc4b — capability ACL. The ENTRY dispatch supplied an
    /// `actor_caps` set (the authenticated edge's assertion) that lacks the
    /// capability the command's `role` requires, and not the `Admin`
    /// wildcard. The command never applies (0 events). `required` is the
    /// command's role-capability ; `held` is the asserted set. Cascades
    /// bypass this gate (they never reach Runtime::dispatch), so System
    /// commands are reachable only internally.
    Unauthorized {
        command: String,
        required: String,
        held: String,
        /// Structured, audit-internal deny cause ("deny-by-default",
        /// "forbid:<policy-id>", "no-active-identity", ...). Recorded on the
        /// Governance::Violation ; NOT rendered by Display — operator/audit only,
        /// never plumbed to a caller-facing error (a policy-enumeration oracle).
        cause: String,
    },
}

/// The verdict of evaluating the active Policy rule set for one principal over
/// (action, resource) — the shared output of `authorize_check` (the live gate)
/// and `explain_authorization` (the dry path). `matched` lists the rule
/// descriptions that matched the (principal, action, resource) patterns, for the
/// explain surface ; a conditional permit is tagged inert (the `when` frontier).
pub(super) enum PolicyOutcome {
    Permitted { matched: Vec<String> },
    Forbidden { policy_id: String, matched: Vec<String> },
    DeniedByDefault { matched: Vec<String> },
}

impl std::fmt::Display for RuntimeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            RuntimeError::UnknownCommand(c) => write!(f, "unknown command: {}", c),
            RuntimeError::UnknownAggregate(a) => write!(f, "unknown aggregate: {}", a),
            RuntimeError::PersistenceRefused(m) => write!(f, "{}", m),
            RuntimeError::GivenFailed { message, .. } => write!(f, "given failed: {}", message),
            RuntimeError::InvariantViolation { name, .. } => write!(f, "invariant violation: {}", name),
            RuntimeError::PayloadInvariantViolation { name, field, value, .. } => {
                write!(f, "{} — {} = {}", name, field, value)
            }
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
            RuntimeError::Unauthorized { command, required, held, .. } => {
                    write!(f, "GOVERNANCE (authz): '{}' denied : requires {} ; caller {}",
                        command, required, held)
                }
        }
    }
}
