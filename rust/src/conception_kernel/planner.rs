//! conception_kernel::planner — the recursive, depth-capped setup-chain engine.
//!
//! THE algorithm half of the conception, and the reason a kernel interpreter is
//! needed at all: a section-concatenating specializer cannot run a recursion.
//! The engine is GENERIC over the grammar — for each precondition it reads the
//! kind's primitives and executes them:
//!
//!   * skip if already produced by an earlier step (`satisfy` tree), or
//!     default-held (`DefaultRule`);
//!   * otherwise find a producer carrying the sought mutation (`ProducerSeek`),
//!     recurse into ITS preconditions (depth-capped), then append it — once,
//!     or N-minus-existing times for `AppendN`.
//!
//! There is no `match kind` here. Adding a kind is a row in `grammar.rs`. The
//! seek/append/default mechanics live in `producers.rs`.
//!
//! Example:
//!   match planner::plan(agg, bulk_cmd) {            // given items.size >= 3
//!       Plan::Chain(steps) => assert_eq!(steps, ["AddItem", "AddItem", "AddItem"]),
//!       Plan::Unsatisfiable => unreachable!(),
//!   }

use crate::ir::{Aggregate, Command};
use std::collections::BTreeSet;

use super::grammar::{self, Precondition};
use super::produced_state::ProducedState;
use super::producers::{append_producer, default_holds, find_producer};
use super::recognize;

/// The recursion bound — matches the live planner's depth cap of 5. A producer
/// chain deeper than this yields a lenient empty chain rather than looping.
pub const DEPTH_CAP: usize = 5;

/// The planner's outcome: an ordered setup chain (command names, possibly empty
/// when defaults already hold), or Unsatisfiable (every producer cascades past
/// the target state — caller skips the test). Unsatisfiable arises only with
/// cascade filtering, a later slice; the current slices always return Chain.
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

    for pre in collect_preconditions(agg, target) {
        let rule = grammar::rule_for(pre.kind);
        if produced.satisfies(&pre, &rule) {
            continue;
        }
        if default_holds(&rule, agg, &pre) {
            continue;
        }
        match find_producer(agg, &pre, rule.producer) {
            Some(producer) => {
                match plan_chain(agg, producer, depth - 1, visited) {
                    Outcome::Chain(sub) => {
                        for c in sub {
                            if !chain.iter().any(|x| x.name == c.name) {
                                chain.push(c);
                                produced.absorb(agg, c);
                            }
                        }
                    }
                    Outcome::Unsatisfiable => {
                        unsatisfiable = true;
                        break;
                    }
                }
                append_producer(&pre, producer, rule.producer, &mut chain, &mut produced, agg);
            }
            // No producer for this precondition: lenient skip (the test fails
            // loudly if the bluebook truly can't reach the state). The
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

/// Parse `cmd`'s givens into the taxonomy's preconditions, then add the
/// lifecycle from_state precondition. Givens outside the taxonomy are skipped.
/// Deduped, given-declaration order preserved (lifecycle precondition last).
fn collect_preconditions(agg: &Aggregate, cmd: &Command) -> Vec<Precondition> {
    let mut out: Vec<Precondition> = Vec::new();
    let mut seen: BTreeSet<Precondition> = BTreeSet::new();
    for g in &cmd.givens {
        if let Some(pre) = recognize::parse_given(&g.expression) {
            if seen.insert(pre.clone()) {
                out.push(pre);
            }
        }
    }
    // Lifecycle from_state: when EVERY transition for this command requires a
    // from_state, the command can only fire from that state — require it as an
    // Equals precondition (the first from_state is the satisfiable choice). A
    // transition with no from_state means the command can fire from default,
    // so no precondition is added.
    if let Some(lc) = &agg.lifecycle {
        let trans: Vec<_> = lc.transitions.iter().filter(|t| t.command == cmd.name).collect();
        if !trans.is_empty() && trans.iter().all(|t| t.from_state.is_some()) {
            if let Some(from) = trans.first().and_then(|t| t.from_state.as_ref()) {
                let pre = Precondition {
                    kind: grammar::Kind::Equals,
                    field: lc.field.clone(),
                    count: 0,
                    target: 0,
                    value: from.clone(),
                };
                if seen.insert(pre.clone()) {
                    out.push(pre);
                }
            }
        }
    }
    out
}
