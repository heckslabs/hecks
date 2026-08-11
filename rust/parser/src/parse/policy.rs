//! The `Policy` construct (`lib/hecksagain/bluebook/ir/policy.rb`) — `on`/
//! `trigger`/`across` filling `on_event`/`trigger_command`/`target_domain`.
//! Stage 2+ work: a policy written inside an aggregate is HOISTED onto the
//! chapter by the builder (the `aggregate` field, deliberately absent from
//! `to_h`) — this parser needs to track which head declared it the same
//! way, even though the wire format never carries it.

use crate::diag::Diagnostic;

pub fn not_implemented(file: &str, line: usize, word: &str) -> Diagnostic {
    Diagnostic::not_yet_implemented(file, line, format!("Policy.{word}"))
}
