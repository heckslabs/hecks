//! conception_kernel::producers — finding and appending setup producers.
//!
//! The seek/append/default half of the engine, driven entirely by the kind's
//! GENERAL primitives (`ProducerSeek`, `DefaultRule`) — no `match kind`. Split
//! from `planner.rs` by concern: the planner owns the recursion, this owns
//! "which command carries the mutation that satisfies a precondition, and how
//! many times to run it".
//!
//! Example:
//!   let prod = find_producer(agg, &pre, ProducerSeek::AppendN);  // an Append cmd

use crate::ir::{Aggregate, Command, MutationOp};

use super::grammar::{DefaultRule, KindRule, Precondition, ProducerSeek};
use super::produced_state::ProducedState;

/// Find a command on `agg` whose direct effects carry the sought mutation.
pub fn find_producer<'a>(
    agg: &'a Aggregate,
    pre: &Precondition,
    seek: ProducerSeek,
) -> Option<&'a Command> {
    match seek {
        // A command that ESTABLISHES set_fact(field = value) — by a Set
        // mutation, or (fallback) a lifecycle transition to that value on the
        // lifecycle field. Both land the same fact (see ProducedState::absorb).
        // Set wins over transition, matching generator's find_equals_producer.
        ProducerSeek::SetTo => {
            let by_set = agg.commands.iter().find(|c| {
                c.mutations.iter().any(|m| {
                    matches!(m.operation, MutationOp::Set)
                        && m.field == pre.field
                        && value_matches(&m.value, &pre.value)
                })
            });
            if by_set.is_some() {
                return by_set;
            }
            if let Some(lc) = &agg.lifecycle {
                if lc.field == pre.field {
                    return lc
                        .transitions
                        .iter()
                        .filter(|t| t.to_state == pre.value)
                        .find_map(|t| agg.commands.iter().find(|c| c.name == t.command));
                }
            }
            None
        }
        ProducerSeek::AppendOnce | ProducerSeek::AppendN => agg.commands.iter().find(|c| {
            c.mutations
                .iter()
                .any(|m| matches!(m.operation, MutationOp::Append) && m.field == pre.field)
        }),
        ProducerSeek::SetIntAtLeast => find_int(agg, pre, true),
        ProducerSeek::SetIntAtMost => find_int(agg, pre, false),
        ProducerSeek::NoneNeeded => None,
    }
}

/// Find a producer landing `pre.field` at an integer satisfying the bound:
/// `>= target` when `at_least`, else `<= target`. For `at_least` bounds with
/// `target <= 1`, an `Increment` on the field also qualifies (one increment
/// lands at 1).
fn find_int<'a>(agg: &'a Aggregate, pre: &Precondition, at_least: bool) -> Option<&'a Command> {
    let by_set = agg.commands.iter().find(|c| {
        c.mutations.iter().any(|m| {
            if !matches!(m.operation, MutationOp::Set) || m.field != pre.field {
                return false;
            }
            match m.value.trim().trim_matches('"').parse::<i64>() {
                Ok(v) => {
                    if at_least {
                        v >= pre.target
                    } else {
                        v <= pre.target
                    }
                }
                Err(_) => false,
            }
        })
    });
    if by_set.is_some() {
        return by_set;
    }
    if at_least && pre.target <= 1 {
        return agg.commands.iter().find(|c| {
            c.mutations
                .iter()
                .any(|m| matches!(m.operation, MutationOp::Increment) && m.field == pre.field)
        });
    }
    None
}

/// Append `producer` to `chain` per the seek's repeat-mode. `AppendN` repeats
/// until the post-absorb append count reaches `pre.count`, subtracting steps
/// already in the chain. Everything else adds it once, deduped by name.
pub fn append_producer<'a>(
    pre: &Precondition,
    producer: &'a Command,
    seek: ProducerSeek,
    chain: &mut Vec<&'a Command>,
    produced: &mut ProducedState,
    agg: &Aggregate,
) {
    if seek == ProducerSeek::AppendN {
        let target = pre.count.max(0) as usize;
        while produced.append_count(&pre.field) < target {
            chain.push(producer);
            produced.absorb(agg, producer);
        }
        return;
    }
    if !chain.iter().any(|c| c.name == producer.name) {
        chain.push(producer);
        produced.absorb(agg, producer);
    }
}

/// Evaluate the kind's `DefaultRule` against the aggregate — the agg-aware half
/// of "already satisfied without a chain step".
pub fn default_holds(rule: &KindRule, agg: &Aggregate, pre: &Precondition) -> bool {
    match rule.default {
        DefaultRule::Always => true,
        DefaultRule::Never => false,
        // LessThan: integers default to 0, and 0 < n for every n > 0.
        DefaultRule::IfDefaultBelow => {
            pre.count > 0
                && agg
                    .attributes
                    .iter()
                    .any(|a| a.name == pre.field && a.attr_type == "Integer")
        }
        // Equals holds at birth: the lifecycle default IS the value, or an
        // attribute's default IS the value. Verbatim port of generator's
        // precondition_default_holds Equals arm.
        DefaultRule::IfDefaultMatches => {
            if let Some(lc) = &agg.lifecycle {
                if lc.field == pre.field && lc.default == pre.value {
                    return true;
                }
            }
            agg.attributes.iter().any(|a| {
                a.name == pre.field && a.default.as_deref().map(|d| d.trim()) == Some(pre.value.as_str())
            })
        }
    }
}

/// Compare a mutation's raw stored value to a precondition value. Verbatim port
/// of generator's `mutation_value_matches`: bare token, quoted, or trimmed.
fn value_matches(raw: &str, value: &str) -> bool {
    raw == value || raw == format!("\"{value}\"") || raw.trim_matches('"') == value
}
