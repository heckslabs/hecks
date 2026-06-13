//! conception_kernel::query — the query starter-test renderer, plan-independent.
//!
//! A query test bootstraps one row via the aggregate's create command, then
//! dispatches the query wired so it matches that row: each param where-clause
//! (IR value `:param`) passes the sample value of the FIELD it filters, so the
//! query input lines up with what the create stored. Literal wheres need no
//! input. The test asserts `count: 1`. No setup-chain PLAN is involved — a
//! create plus the query — so it renders below the planner. generator.rs
//! delegates until it is deleted at the final gate.
//!
//! Usage:
//!   let src = conception_kernel::query::query_test(agg, q);

use crate::conception_kernel::bootstrap::pick_create_command;
use crate::conception_kernel::emit::{join_kvs, kwargs_inline};
use crate::conception_kernel::sample::sample_value;
use crate::ir::{Aggregate, Query};

/// Render the starter test for one query: bootstrap a row, wire param wheres to
/// their field's sample value, assert the query returns it.
pub fn query_test(agg: &Aggregate, q: &Query) -> String {
    let setup =
        pick_create_command(agg).map(|c| format!("    setup  {:?}{}\n", c.name, kwargs_inline(c)));
    // Wire each param where-clause (IR value `:param`) to the sample value of
    // the FIELD it filters, so the query matches its own setup row. The create
    // stores `field: sample_value(<field type>)` ; the query input passes that
    // same sample under the param name. Literal wheres (no leading colon) need
    // no input. (2026-06-13 — pizzas ByDescription returned 0 matches before.)
    let inputs: Vec<(String, String)> = q
        .wheres
        .iter()
        .filter_map(|w| {
            w.value.strip_prefix(':').map(|param| {
                let sample = agg
                    .attributes
                    .iter()
                    .find(|a| a.name == w.field)
                    .map(|a| sample_value(&a.attr_type))
                    .unwrap_or_else(|| sample_value("String"));
                (param.to_string(), sample)
            })
        })
        .collect();
    let mut s = String::new();
    s.push_str(&format!("  test \"{} returns matching records\" do\n", q.name));
    s.push_str(&format!("    tests {:?}, on: {:?}, kind: :query\n", q.name, agg.name));
    if let Some(line) = setup {
        s.push_str(&line);
    }
    if !inputs.is_empty() {
        s.push_str(&format!("    input  {}\n", join_kvs(&inputs)));
    }
    s.push_str("    expect count: 1\n");
    s.push_str("  end\n");
    s
}
