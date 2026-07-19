//! Payload gate — the anticorruption layer at the dispatch threshold.
//!
//! "The domain can always assume its payloads are valid" (Chris,
//! 2026-07-18, inbox/PLAN-payload-gate-acl.md). This module judges the
//! INCOMING command attrs against the value-object invariants declared
//! in the bluebook — BEFORE hydration, before mutations, before any
//! event. A refusal produces zero state touch : no record, no event,
//! no cascade. Parse, don't validate : an invalid Fee never exists
//! inside the boundary.
//!
//! Phase 1 scope (invariants bite) : single-attribute value objects —
//! the wrapper shape (`Fee { cents }`, `Amount { value }`) that every
//! canon VO-typed command attribute uses. The incoming scalar binds to
//! the VO's inner attribute name and each invariant predicate runs
//! through the SAME evaluator `given` blocks use. Multi-attribute VO
//! payloads (nested construction) arrive with the one_of/type work —
//! see inbox/GRAMMAR-one-of-closed-value-sets.md.
//!
//! Absence passes : a missing attr is the REQUIRED gate's concern
//! (phase B on the card), not the invariant's — and numeric coercion
//! of Null is 0, which would judge absent values arbitrarily.
//!
//! Usage (wired in command_dispatch::dispatch_inner) :
//!   payload_gate::check(&rt.domain.aggregates[agg_idx], cmd, &attrs)?;

use std::collections::HashMap;

use crate::ir::{Aggregate, Command};
use super::aggregate_state::AggregateState;
use super::interpreter;
use super::{RuntimeError, Value};

/// Conservative whitelist of what the expression interpreter provably
/// speaks at the gate : `&&`/`||` chains of comparisons whose terms are
/// quoted strings, numeric literals (int or float), or identifiers
/// (optionally `.size` / `.length`). Anything else — negation, method
/// calls, assignment, blocks — is NOT judgeable and passes the gate
/// unjudged rather than being refused by incomprehension.
fn judgeable(expr: &str) -> bool {
    expr.split("&&")
        .flat_map(|p| p.split("||"))
        .all(|clause| {
            let c = clause.trim();
            for op in ["==", "!=", ">=", "<=", ">", "<"] {
                if let Some((l, r)) = c.split_once(op) {
                    return simple_term(l) && simple_term(r);
                }
            }
            false
        })
}

fn simple_term(t: &str) -> bool {
    let t = t.trim();
    if t.is_empty() {
        return false;
    }
    if t.starts_with('"') && t.ends_with('"') && t.len() >= 2 {
        return true;
    }
    if t.parse::<f64>().is_ok() {
        return true;
    }
    let base = t
        .strip_suffix(".size")
        .or_else(|| t.strip_suffix(".length"))
        .unwrap_or(t);
    !base.is_empty()
        && base.chars().next().map(|c| c.is_alphabetic() || c == '_').unwrap_or(false)
        && base.chars().all(|c| c.is_alphanumeric() || c == '_')
}

/// Judge every VO-typed command attribute's incoming value against the
/// VO's declared invariants. First violation refuses the dispatch with
/// a field-targeted error ; `Ok(())` means the payload is admissible
/// (at this gate — givens and lifecycle still rule downstream).
pub fn check(
    agg: &Aggregate,
    cmd: &Command,
    attrs: &HashMap<String, Value>,
    cascade_hinted: bool,
) -> Result<(), RuntimeError> {
    // REFERENCES — a command's declared reference must resolve to an id.
    // The Ruby DSL states this contract as the DEFAULT (`reference_to(type,
    // validate: :exists)` in command_builder.rb) ; before 2026-07-18 the
    // Rust dispatcher would counter-mint a fresh record when the ref was
    // absent — ReturnTool without a loan invented a loan. Accepted id
    // sources mirror the resolved_id chain : the ref's own snake_case key,
    // the universal `id` fallback, or a cascade hint (a hinted dispatch is
    // the cascade machinery's own plumbing — trusted, its FK rides the
    // event data).
    // The enforced class is exactly the COUNTER-MINT : a SELF-reference
    // on an identity-LESS aggregate, absent from the payload, falls all
    // the way through the resolved_id chain to a fresh counter-minted id
    // — ReturnTool with no loan invented a Loan born "returned". Two
    // reference shapes legitimately dispatch without an explicit key and
    // are deferred, not judged :
    //   - self-ref on an identity-BEARING aggregate — the identity
    //     machinery resolves it (natural key : Gate.Retire by name ;
    //     ROOT-3 default injection ; singleton reuse) ;
    //   - FOREIGN refs — absence leaves a field empty, mints nothing ;
    //     corpus flows rely on implicit-singleton parents (restructure's
    //     Placement.Add). Enforcing those needs the corpus survey —
    //     named follow-on on PLAN-payload-gate-acl.md.
    if !cascade_hinted {
        for r in &cmd.references {
            if r.target != agg.name || agg.identified_by.is_some() {
                continue;
            }
            let present = [r.name.as_str(), "id"].iter().any(|k| {
                matches!(attrs.get(*k), Some(Value::Str(s)) if !s.trim().is_empty())
                    || matches!(attrs.get(*k), Some(Value::Int(_)))
            });
            if !present {
                return Err(RuntimeError::MissingAttribute(r.name.clone()));
            }
        }
    }
    // Empty state : invariants are value-intrinsic — they may not read
    // aggregate state, and binding through `attrs` alone enforces that.
    let empty_state = AggregateState {
        id: String::new(),
        fields: HashMap::new(),
        deleted: false,
    };

    // REQUIRED (phase B) — explicit opt-in only : `attribute :name, X,
    // required: true`. Both grammars already carry the flag (Ruby
    // structure/attribute.rb documents the contract : "dispatch refuses
    // when absent/Null/empty") ; unmarked attributes stay optional, so
    // the corpus's free-omission dispatch style (Tools::ShellTool.Bash
    // omitting :description) is untouched.
    for cmd_attr in &cmd.attributes {
        if !cmd_attr.required {
            continue;
        }
        let missing = match attrs.get(&cmd_attr.name) {
            None | Some(Value::Null) => true,
            Some(Value::Str(s)) => s.trim().is_empty(),
            Some(Value::List(items)) => items.is_empty(),
            Some(_) => false,
        };
        if missing {
            return Err(RuntimeError::MissingAttribute(cmd_attr.name.clone()));
        }
    }

    // ONE_OF membership (GRAMMAR-one-of, 2026-07-19) — closed vocabularies
    // refuse anything outside the set. Two homes, one rule :
    //   - scalar sugar : the attribute's own enum_values
    //   - whole-value members : the VO's members, judged on the
    //     DISCRIMINANT (the value the form submits ; the first attribute)
    // Absence still passes — presence is the required arm's concern.
    for cmd_attr in &cmd.attributes {
        let Some(raw) = attrs.get(&cmd_attr.name) else { continue };
        if matches!(raw, Value::Null) {
            continue;
        }
        let sent = raw.to_string();
        if sent.trim().is_empty() {
            continue;
        }
        let vocabulary: Vec<String> = if !cmd_attr.enum_values.is_empty() {
            cmd_attr.enum_values.clone()
        } else if let Some(vo) = agg.value_objects.iter().find(|v| v.name == cmd_attr.attr_type) {
            vo.members
                .iter()
                .filter_map(|m| m.first().map(|(_, v)| v.clone()))
                .collect()
        } else {
            vec![]
        };
        if !vocabulary.is_empty() && !vocabulary.iter().any(|v| v == &sent) {
            return Err(RuntimeError::PayloadInvariantViolation {
                name: format!("must be one of: {}", vocabulary.join(", ")),
                expression: "one_of".to_string(),
                field: cmd_attr.name.clone(),
                value: sent,
            });
        }
    }

    for cmd_attr in &cmd.attributes {
        let Some(vo) = agg.value_objects.iter().find(|v| v.name == cmd_attr.attr_type) else {
            continue;
        };
        if vo.invariants.is_empty() || vo.attributes.len() != 1 {
            // Phase 1 : wrapper-shaped VOs only (see module doc).
            continue;
        }
        let Some(raw) = attrs.get(&cmd_attr.name) else {
            continue; // absence is the required-gate's job
        };
        if matches!(raw, Value::Null) {
            continue;
        }
        let mut binding: HashMap<String, Value> = HashMap::new();
        binding.insert(vo.attributes[0].name.clone(), raw.clone());
        for inv in &vo.invariants {
            // The gate must never refuse what it cannot understand : only
            // predicates the expression interpreter provably speaks are
            // JUDGED here ; richer Ruby (local assignment, .split, blocks —
            // codegen's four-segment phrase invariant) passes unjudged, and
            // the Ruby runtime, where invariants are live Procs, enforces
            // it. Refusal requires a verdict, not incomprehension.
            if !judgeable(&inv.expression) {
                continue;
            }
            if !interpreter::evaluate_predicate(&inv.expression, &empty_state, &binding) {
                return Err(RuntimeError::PayloadInvariantViolation {
                    name: inv.name.clone(),
                    expression: inv.expression.clone(),
                    field: cmd_attr.name.clone(),
                    value: raw.to_string(),
                });
            }
        }
    }
    Ok(())
}
