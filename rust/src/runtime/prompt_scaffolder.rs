//! [antibody-exempt: rust/src/runtime/prompt_scaffolder.rs — kernel-floor
//!  LLM dispatcher port (Phase 2 i221) ; parallels existing kernel-floor
//!  runtime markers on adapter_io.rs / shell_dispatcher.rs / adapter_llm.rs.
//!  Retires when the LLM dispatch becomes bluebook-driven via :llm
//!  hecksagon adapters resolved at runtime + a dedicated dispatcher
//!  bluebook (filed as follow-up).]
//!
//! PromptScaffolder — Rust mirror of ruby/hecks/runtime/prompt_scaffolder.rb
//!
//! Builds the substituted prompt fed to a provider from a hecksagon
//! `:llm` adapter. The Ruby implementation also composes a SYSTEM /
//! USER envelope for `scaffold :command_metadata` ; this Phase-2 Rust
//! port implements only the {{placeholder}} substitution path that the
//! :dream_image adapter actually uses today. The full envelope shape
//! (PII strip + loop-guard + command_metadata block) lives in Ruby
//! until a Rust caller needs it.
//!
//! Substitution rules (parity with `LlmDispatcher.substitute_placeholders`) :
//!
//!   - `{{name}}` is replaced with the value at attrs["name"] OR
//!     state.fields["name"] (attrs win — runtime kwargs override
//!     persisted state).
//!   - Unknown placeholders pass through verbatim (no panic, no
//!     fallback) so debugging stays honest.
//!   - Values are stringified via Display.
//!   - Multiple occurrences of the same placeholder all substitute.

use crate::runtime::AggregateState;
use std::collections::HashMap;

/// Substitute `{{placeholder}}` tokens in `template` from runtime
/// `attrs` first, then from `state.fields` as a fallback. Returns the
/// fully substituted prompt — exactly what the dispatcher hashes for
/// SHA-256 fixture lookup, exactly what the provider receives.
///
/// `state` is optional ; pass `None` for unit-level substitution
/// (parity with `LlmDispatcher.substitute_placeholders` whose attrs
/// arg is the only source).
pub fn substitute(
    template: &str,
    attrs: &HashMap<String, String>,
    state: Option<&AggregateState>,
) -> String {
    let mut out = String::with_capacity(template.len());
    let bytes = template.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if i + 4 <= bytes.len() && bytes[i] == b'{' && bytes[i + 1] == b'{' {
            if let Some(close) = template[i + 2..].find("}}") {
                let name = &template[i + 2..i + 2 + close];
                if let Some(val) = lookup(name, attrs, state) {
                    out.push_str(&val);
                } else {
                    out.push_str(&template[i..i + 2 + close + 2]);
                }
                i += 2 + close + 2;
                continue;
            }
        }
        out.push(bytes[i] as char);
        i += 1;
    }
    out
}

/// Resolve a placeholder name. Attrs win over state — runtime kwargs
/// (the literal arg the user passed on the dispatch) override whatever
/// is persisted on the aggregate. State falls back so a prompt
/// referencing `{{seed_image}}` resolves to the just-stored field even
/// when the dispatcher itself wasn't given that kwarg explicitly.
fn lookup(
    name: &str,
    attrs: &HashMap<String, String>,
    state: Option<&AggregateState>,
) -> Option<String> {
    if let Some(v) = attrs.get(name) {
        return Some(v.clone());
    }
    if let Some(s) = state {
        if let Some(v) = s.fields.get(name) {
            return Some(v.to_string());
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn substitutes_from_attrs() {
        let mut attrs = HashMap::new();
        attrs.insert("who".into(), "Miette".into());
        assert_eq!(substitute("Hi {{who}}!", &attrs, None), "Hi Miette!");
    }

    #[test]
    fn falls_back_to_state_fields() {
        let mut s = AggregateState::new("x");
        s.set("seed", crate::runtime::Value::Str("blue".into()));
        assert_eq!(substitute("see {{seed}}", &HashMap::new(), Some(&s)), "see blue");
    }

    #[test]
    fn attrs_win_over_state() {
        let mut s = AggregateState::new("x");
        s.set("k", crate::runtime::Value::Str("from-state".into()));
        let mut a = HashMap::new();
        a.insert("k".into(), "from-attrs".into());
        assert_eq!(substitute("{{k}}", &a, Some(&s)), "from-attrs");
    }

    #[test]
    fn leaves_unknown_placeholders_verbatim() {
        assert_eq!(substitute("{{missing}} yo", &HashMap::new(), None), "{{missing}} yo");
    }

    #[test]
    fn substitutes_repeats() {
        let mut a = HashMap::new();
        a.insert("x".into(), "yo".into());
        assert_eq!(substitute("{{x}} and {{x}}", &a, None), "yo and yo");
    }
}
