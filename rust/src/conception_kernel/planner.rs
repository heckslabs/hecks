//! conception_kernel::planner — the recursive, depth-capped setup-chain engine.
//!
//! THE algorithm half of the conception, and the reason a kernel interpreter is
//! needed at all: a section-concatenating specializer cannot run a recursion.
//! The engine is GENERIC over the grammar — for each precondition it reads the
//! kind's primitives (`producer`, `default`, `satisfy`) and executes them:
//!
//!   * skip if already produced by an earlier step (`satisfy` primitive), or
//!     default-held (`default` primitive);
//!   * otherwise find a producer carrying the sought mutation (`producer`
//!     primitive), recurse into ITS preconditions (depth-capped), then append
//!     it — once, or N-minus-existing times for `AppendN`.
//!
//! There is no `match kind` here. Adding a kind is a row in `grammar.rs`.
//!
//! Example:
//!   match planner::plan(agg, bulk_cmd) {            // given items.size >= 3
//!       Plan::Chain(steps) => assert_eq!(steps, ["AddItem", "AddItem", "AddItem"]),
//!       Plan::Unsatisfiable => unreachable!(),
//!   }

use crate::ir::{Aggregate, Command, MutationOp};
use std::collections::BTreeSet;

use super::grammar::{self, DefaultRule, Precondition, ProducerSeek};
use super::produced_state::ProducedState;
use super::recognize;

/// The recursion bound — matches the live planner's depth cap of 5. A producer
/// chain deeper than this yields a lenient empty chain rather than looping.
pub const DEPTH_CAP: usize = 5;

/// The planner's outcome: an ordered setup chain (command names, possibly
/// empty when defaults already hold), or Unsatisfiable (every producer cascades
/// past the target state — caller skips the test). Unsatisfiable arises only
/// with cascade filtering, a later slice; the first slice always returns Chain.
#[derive(Debug, PartialEq, Eq)]
pub enum Plan {
    Chain(Vec<String>),
    Unsatisfiable,
}

enum Outcome<'a> {
    Chain(Vec<&'a Command>),
    Unsatisfiable,
}

/// Plan the setup chain that brings `agg` to the state `cmd`'s givens require.
pub fn plan(agg: &Aggregate, cmd: &Command) -> Plan {
    match plan_chain(agg, cmd, DEPTH_CAP, &mut Vec::new()) {
        Outcome::Chain(cs) => Plan::Chain(cs.iter().map(|c| c.name.clone()).collect()),
        Outcome::Unsatisfiable => Plan::Unsatisfiable,
    }
}

fn plan_chain<'a>(
    agg: &'a Aggregate,
    target: &'a Command,
    depth: usize,
    visited: &mut Vec<&'a str>,
) -> Outcome<'a> {
    if depth == 0 || visited.contains(&target.name.as_str()) {
        return Outcome::Chain(Vec::new());
    }
    visited.push(target.name.as_str());
    let mut chain: Vec<&Command> = Vec::new();
    let mut produced = ProducedState::default();
    let mut unsatisfiable = false;

    for pre in collect_preconditions(target) {
        let rule = grammar::rule_for(pre.kind);
        if produced.satisfies(&pre, &rule) {
            continue;
        }
        if rule.default == DefaultRule::Always {
            continue;
        }
        match find_producer(agg, &pre, rule.producer) {
            Some(producer) => {
                match plan_chain(agg, producer, depth - 1, visited) {
                    Outcome::Chain(sub) => {
                        for c in sub {
                            if !chain.iter().any(|x| x.name == c.name) {
                                chain.push(c);
                                produced.absorb(c);
                            }
                        }
                    }
                    Outcome::Unsatisfiable => {
                        unsatisfiable = true;
                        break;
                    }
                }
                append_producer(&pre, producer, rule.producer, &mut chain, &mut produced);
            }
            // No producer for this precondition: lenient skip (the test will
            // fail loudly if the bluebook truly can't reach the state). The
            // Unsatisfiable-via-cascade path is a later slice.
            None => {}
        }
    }

    visited.pop();
    if unsatisfiable {
        Outcome::Unsatisfiable
    } else {
        Outcome::Chain(chain)
    }
}

/// Parse `cmd`'s givens into the preconditions this slice knows. Givens outside
/// the slice (integer kinds) are skipped here — they arrive with their kinds in
/// a later slice. Deduped, given-declaration order preserved.
fn collect_preconditions(cmd: &Command) -> Vec<Precondition> {
    let mut out: Vec<Precondition> = Vec::new();
    let mut seen: BTreeSet<Precondition> = BTreeSet::new();
    for g in &cmd.givens {
        if let Some(pre) = recognize::parse_given(&g.expression) {
            if seen.insert(pre.clone()) {
                out.push(pre);
            }
        }
    }
    out
}

/// Find a command on `agg` whose direct effects carry the sought mutation.
fn find_producer<'a>(
    agg: &'a Aggregate,
    pre: &Precondition,
    seek: ProducerSeek,
) -> Option<&'a Command> {
    match seek {
        ProducerSeek::SetTo => agg.commands.iter().find(|c| {
            c.mutations.iter().any(|m| {
                matches!(m.operation, MutationOp::Set)
                    && m.field == pre.field
                    && value_matches(&m.value, &pre.value)
            })
        }),
        ProducerSeek::AppendOnce | ProducerSeek::AppendN => agg.commands.iter().find(|c| {
            c.mutations
                .iter()
                .any(|m| matches!(m.operation, MutationOp::Append) && m.field == pre.field)
        }),
        ProducerSeek::NoneNeeded => None,
    }
}

/// Append `producer` to `chain` per the seek's repeat-mode. `AppendN` repeats
/// until the post-absorb append count reaches `pre.count`, subtracting steps
/// already in the chain. Everything else adds it once, deduped by name.
fn append_producer<'a>(
    pre: &Precondition,
    producer: &'a Command,
    seek: ProducerSeek,
    chain: &mut Vec<&'a Command>,
    produced: &mut ProducedState,
) {
    if seek == ProducerSeek::AppendN {
        let target = pre.count.max(0) as usize;
        while produced.append_count(&pre.field) < target {
            chain.push(producer);
            produced.absorb(producer);
        }
        return;
    }
    if !chain.iter().any(|c| c.name == producer.name) {
        chain.push(producer);
        produced.absorb(producer);
    }
}

/// Compare a mutation's raw stored value to a precondition value, tolerating
/// surrounding quotes and a leading symbol colon.
fn value_matches(raw: &str, value: &str) -> bool {
    let cleaned = raw.trim().trim_matches('"').trim_start_matches(':');
    cleaned == value
}
