//! Lifecycle validator
//!
//! GENERATED FILE — do not edit.
//! Source:    hecks_conception/capabilities/lifecycle_validator_shape/
//! Regenerate: bin/specialize lifecycle --output hecks_life/src/lifecycle_validator.rs
//! Contract:  specializer.hecksagon :specialize_lifecycle shell adapter
//! Tests:     hecks_life/tests/lifecycle_validator_test.rs
//!
//! Catches contradictions in lifecycle declarations — patterns where
//! a transition is structurally unreachable from any state the
//! aggregate can actually be in.
//!
//! The most common bug this catches:
//!
//!   attribute :status, default: "active"
//!   lifecycle :status do
//!     transition "OpenRecord" => "active", from: "none"
//!   end
//!
//! New aggregates start with `status = "active"` (the default).
//! `OpenRecord` requires `from: "none"`. Nothing transitions to "none".
//! Therefore OpenRecord can never fire. The bluebook is contradictory.
//!
//! Two checks:
//!
//! 1. **Unreachable from_state.** A transition's `from:` value must be
//!    either the lifecycle default OR the to_state of some other
//!    transition. Otherwise the transition is dead.
//!
//! 2. **Stuck default.** If the lifecycle has transitions but none of
//!    them can fire from the default state, the aggregate is stuck
//!    in default forever. Warning.
//!
//! Surface:
//!
//!   hecks-life check-lifecycle path/to/bluebook.bluebook
//!   hecks-life check-lifecycle path/to/bluebook.bluebook --strict
//!
//! Exit code:
//!   0 — no errors (and no warnings if --strict isn't set)
//!   1 — at least one error, or --strict and at least one warning

pub use crate::diagnostic::{Finding, Severity};
use crate::ir::{Aggregate, Command, Domain, Lifecycle, MutationOp};
use std::collections::BTreeSet;

pub struct Report {
    pub findings: Vec<Finding>,
}

impl Report {
    pub fn errors(&self) -> usize {
        self.findings.iter().filter(|f| f.severity == Severity::Error).count()
    }
    pub fn warnings(&self) -> usize {
        self.findings.iter().filter(|f| f.severity == Severity::Warning).count()
    }
    pub fn passes(&self, strict: bool) -> bool {
        if self.errors() > 0 { return false; }
        if strict && self.warnings() > 0 { return false; }
        true
    }
}

pub fn check(domain: &Domain) -> Report {
    let mut findings = Vec::new();
    for agg in &domain.aggregates {
        if let Some(lc) = &agg.lifecycle {
            check_aggregate(agg, lc, &mut findings);
        }
        check_given_coverage(agg, &mut findings);
        check_mutation_references(agg, &mut findings);
    }
    Report { findings }
}

/// `then_set :field, to: :symbol` references the command's `:symbol`
/// attribute or reference at runtime. If neither exists, the mutation
/// is broken — at runtime the field stays null because there's nothing
/// to copy from. Flag it.
///
/// Also flags two clock-touching anti-patterns the runtime synthesizes:
///   • `to: :now` — current ISO timestamp
///   • `to: seconds_since(:field)` — elapsed seconds
/// Both reach into infrastructure (the system clock) from inside the
/// domain. DDD: time is a Clock port — inject it as a command attribute
/// instead of having the runtime supply it.
fn check_mutation_references(agg: &Aggregate, out: &mut Vec<Finding>) {
    for cmd in &agg.commands {
        for m in &cmd.mutations {
            // Only Set mutations have a value to resolve. Append /
            // Increment / Decrement / Toggle work differently.
            if !matches!(m.operation, MutationOp::Set) { continue; }
            let raw = m.value.trim();

            // Clock anti-patterns — flag specifically with a hint.
            if raw == ":now" || raw == "now" {
                out.push(Finding::err(
                    format!("{}.{}", agg.name, cmd.name),
                    format!(
                        "then_set :{} reaches the system clock via :now — \
                         the domain shouldn't grab time, it's infrastructure. \
                         Inject it: `attribute :{}, String` on the command + \
                         `then_set :{}, to: :{}` so the caller (test, app, \
                         hecksagon adapter) provides the timestamp.",
                        m.field, m.field, m.field, m.field,
                    ),
                ));
                continue;
            }
            if raw.starts_with("seconds_since(") {
                out.push(Finding::err(
                    format!("{}.{}", agg.name, cmd.name),
                    format!(
                        "then_set :{} uses seconds_since(...) — the runtime \
                         synthesizes elapsed time from the system clock. \
                         Inject the elapsed value as a command attribute \
                         instead, computed by the caller (Clock port).",
                        m.field,
                    ),
                ));
                continue;
            }

            let Some(sym) = raw.strip_prefix(':') else { continue };
            // Allow further wrapping (e.g. trailing whitespace before
            // a brace). Only flag bare-identifier symbols.
            let name: String = sym.chars()
                .take_while(|c| c.is_alphanumeric() || *c == '_')
                .collect();
            if name.is_empty() { continue; }

            let in_attrs = cmd.attributes.iter().any(|a| a.name == name);
            let in_refs  = cmd.references.iter().any(|r| r.name == name);
            if !in_attrs && !in_refs {
                out.push(Finding::err(
                    format!("{}.{}", agg.name, cmd.name),
                    format!(
                        "then_set :{} references :{} but the command has \
                         neither an attribute nor a reference named {:?} — \
                         the field will stay null at runtime",
                        m.field, name, name,
                    ),
                ));
            }
        }
    }
}

/// Givens of the form `<field> == "<value>"` need a producer in the
/// same aggregate — some command's `then_set <field>, to: "<value>"`,
/// or a lifecycle transition with `<field>` as its lifecycle field
/// and `<value>` as its to_state. Otherwise the gate is unreachable
/// and the command can never fire.
fn check_given_coverage(agg: &Aggregate, out: &mut Vec<Finding>) {
    let producible = collect_producible_states(agg);

    for cmd in &agg.commands {
        for given in &cmd.givens {
            let Some((field, value)) = parse_equality(&given.expression) else { continue };
            // Lifecycle defaults satisfy themselves.
            if let Some(lc) = &agg.lifecycle {
                if lc.field == field && lc.default == value { continue; }
            }
            if !producible.contains(&(field.clone(), value.clone())) {
                out.push(Finding::err(
                    format!("{}.{}", agg.name, cmd.name),
                    format!(
                        "given `{} == {:?}` is unreachable — no command \
                         sets {} to {:?} and no lifecycle transition \
                         produces it",
                        field, value, field, value,
                    ),
                ));
            }
        }
    }
}

fn collect_producible_states(agg: &Aggregate) -> BTreeSet<(String, String)> {
    let mut produced: BTreeSet<(String, String)> = BTreeSet::new();
    // From every aggregate attribute's `default:` value. The runtime
    // initializes the field to that default on every fresh aggregate,
    // so the state is reachable without any command needing to produce it.
    for attr in &agg.attributes {
        if let Some(d) = &attr.default {
            let val = d.trim_matches('"').to_string();
            if !val.is_empty() {
                produced.insert((attr.name.clone(), val));
            }
        }
    }
    // From every command's then_set Set mutations.
    for cmd in &agg.commands {
        for m in &cmd.mutations {
            if let MutationOp::Set = m.operation {
                let val = m.value.trim_matches('"').to_string();
                produced.insert((m.field.clone(), val));
            }
        }
    }
    // From every lifecycle transition's to_state.
    if let Some(lc) = &agg.lifecycle {
        for t in &lc.transitions {
            produced.insert((lc.field.clone(), t.to_state.clone()));
        }
    }
    produced
}

/// Parse `<field> == "<value>"`. Returns None for non-equality or
/// non-quoted-string-RHS forms — the validator can't reason about
/// expressions like "size > 10" or "must have elapsed".
fn parse_equality(expr: &str) -> Option<(String, String)> {
    let parts: Vec<&str> = expr.splitn(2, "==").collect();
    if parts.len() != 2 { return None; }
    let field = parts[0].trim().to_string();
    if field.is_empty() || !field.chars().all(|c| c.is_alphanumeric() || c == '_') {
        return None;
    }
    let raw = parts[1].trim().trim_end_matches('}').trim();
    if !raw.starts_with('"') { return None; }
    let end = raw[1..].find('"')? + 1;
    Some((field, raw[1..end].to_string()))
}

// (`Command` will be unused if no future check needs it; suppress
// the warning preemptively.)
#[allow(dead_code)]
fn _force_command_use(_c: &Command) {}

fn check_aggregate(agg: &Aggregate, lc: &Lifecycle, out: &mut Vec<Finding>) {
    // Reachable states: the lifecycle default plus every transition's
    // to_state. Anything outside this set is unreachable, so a
    // transition with `from:` pointing outside it is dead code.
    let mut reachable: BTreeSet<String> = BTreeSet::new();
    if !lc.default.is_empty() {
        reachable.insert(lc.default.clone());
    }
    for t in &lc.transitions {
        reachable.insert(t.to_state.clone());
    }

    for t in &lc.transitions {
        if let Some(from) = &t.from_state {
            if !reachable.contains(from) {
                out.push(Finding::err(
                    format!("{}.{}", agg.name, t.command),
                    format!(
                        "transition's from: {:?} is unreachable — \
                         the {:?} field can only be {} \
                         (default {:?} + transition to_states), so this \
                         transition can never fire",
                        from, lc.field,
                        format_set(&reachable),
                        lc.default,
                    ),
                ));
            }
        }
    }

    // Stuck-default warning: if the lifecycle has transitions but none
    // can fire when the field is at its default value, the aggregate
    // is permanently stuck in default. (Transitions with from_state =
    // None fire from any state including default.)
    if !lc.transitions.is_empty() {
        let any_fires_from_default = lc.transitions.iter().any(|t| match &t.from_state {
            None => true,
            Some(from) => from == &lc.default,
        });
        if !any_fires_from_default {
            out.push(Finding::warn(
                format!("{}.lifecycle({})", agg.name, lc.field),
                format!(
                    "no transition can fire from the default state {:?} — \
                     fresh aggregates will be stuck forever",
                    lc.default,
                ),
            ));
        }
    }
}

fn format_set(set: &BTreeSet<String>) -> String {
    let v: Vec<String> = set.iter().map(|s| format!("{:?}", s)).collect();
    if v.is_empty() { "{}".into() } else { format!("{{{}}}", v.join(", ")) }
}
