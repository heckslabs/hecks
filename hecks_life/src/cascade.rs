//! Static cascade extraction. Walks emit→policy→trigger from a
//! given source command and returns the ordered list of events the
//! runtime would publish (assuming each step actually fires).
//!
//! Used by the test generator to lock down each command's cascade
//! as `expect emits: [...]` — drift in the bluebook's policies
//! surfaces as test failure.

use crate::ir::Domain;

pub fn cascade_emits(domain: &Domain, cmd_name: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut visited: std::collections::BTreeSet<String> = std::collections::BTreeSet::new();
    walk(domain, cmd_name, &mut out, &mut visited);
    out
}

fn walk(domain: &Domain, cmd_name: &str, out: &mut Vec<String>,
        visited: &mut std::collections::BTreeSet<String>) {
    if !visited.insert(cmd_name.to_string()) { return; }
    let Some(cmd) = find_cmd(domain, cmd_name) else { return };
    let Some(ref ev) = cmd.emits else { return };
    out.push(ev.clone());
    for p in &domain.policies {
        if &p.on_event == ev {
            walk(domain, &p.trigger_command, out, visited);
        }
    }
}

fn find_cmd<'a>(d: &'a Domain, name: &str) -> Option<&'a crate::ir::Command> {
    d.aggregates.iter().flat_map(|a| a.commands.iter()).find(|c| c.name == name)
}
