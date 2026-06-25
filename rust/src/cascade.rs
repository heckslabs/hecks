//! Static cascade extraction. Walks emit→policy→trigger from a
//! given source command and returns the ordered list of events the
//! runtime would publish (assuming each step actually fires).
//!
//! Used by the test generator to lock down each command's cascade
//! as `expect emits: [...]` — drift in the bluebook's policies
//! surfaces as test failure.
//!
//! Cycle detection mirrors the runtime PolicyEngine: a policy is
//! blocked from re-entering only WHILE it's mid-flight (on the
//! recursion stack). Diamond paths — same command reached via two
//! distinct policies — are walked both times so the predicted emit
//! list matches drain_policies' actual output.

use crate::ir::Domain;

pub fn cascade_emits(domain: &Domain, cmd_name: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut policy_stack: Vec<String> = Vec::new();
    walk(domain, cmd_name, &mut out, &mut policy_stack);
    out
}

fn walk(domain: &Domain, cmd_name: &str, out: &mut Vec<String>,
        policy_stack: &mut Vec<String>) {
    let Some((agg_name, cmd)) = find_cmd(domain, cmd_name) else { return };
    let Some(ref ev) = cmd.emits else { return };
    out.push(ev.clone());
    for p in &domain.policies {
        // gap #1b — match the bare event name, then honour an
        // aggregate qualifier : a policy declared `on "Agg.Event"`
        // fires only when the emitting aggregate IS `Agg`. Mirrors
        // the runtime PolicyEngine::react filter.
        if p.event_name() != ev { continue; }
        if let Some(q) = p.event_qualifier() {
            if q != agg_name { continue; }
        }
        // Mirror runtime PolicyEngine: skip a policy that is already
        // on the recursion stack (in_flight). Allows diamond fan-in
        // through different policies; blocks self-recursive cycles.
        if policy_stack.contains(&p.name) { continue; }
        policy_stack.push(p.name.clone());
        walk(domain, &p.trigger_command, out, policy_stack);
        policy_stack.pop();
    }
}

fn find_cmd<'a>(d: &'a Domain, name: &str) -> Option<(&'a str, &'a crate::ir::Command)> {
    d.aggregates.iter().find_map(|a| {
        a.commands.iter().find(|c| c.name == name).map(|c| (a.name.as_str(), c))
    })
}
