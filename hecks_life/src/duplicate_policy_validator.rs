//! Duplicate policy validator
//!
//! GENERATED FILE — do not edit.
//! Source:    hecks_conception/capabilities/duplicate_policy_validator_shape/
//! Regenerate: bin/specialize duplicate_policy --output hecks_life/src/duplicate_policy_validator.rs
//! Contract:  specializer.hecksagon :specialize_duplicate_policy shell adapter
//! Tests:     hecks_life/tests/duplicate_policy_validator_test.rs
//!
//! Catches bluebooks that declare two or more policies wired to the
//! same `(on_event, trigger_command)` pair. Today this silently
//! coexists — the runtime fires every matching policy in declaration
//! order, so the trigger command runs twice per event. That's a
//! cascade bug with no error message.
//!
//! Example of the bug:
//!
//!   policy "BeatTicks"     do; on "HeartBeat"; trigger "Tick";        end
//!   policy "BeatTicksAgain" do; on "HeartBeat"; trigger "Tick";        end
//!
//! Both policies fire on HeartBeat. Both call Tick. The second is
//! almost certainly a leftover from editing/renaming; even if it's
//! intentional, one policy with a clearer name does the job.
//!
//! Surface:
//!
//!   hecks-life check-duplicate-policies path/to/bluebook.bluebook
//!
//! Exit code:
//!   0 — no duplicate (event, trigger) pairs
//!   1 — at least one pair shared by >1 policy
//!
//! This validator is a flat walk over `domain.policies` — no runtime
//! boot, no cascade traversal. Group by key, report groups of size >1.

pub use crate::diagnostic::{Finding, Severity};
use crate::ir::{Domain, Policy};
use std::collections::BTreeMap;

pub struct Report {
    pub findings: Vec<Finding>,
}

impl Report {
    pub fn errors(&self) -> usize {
        self.findings.iter().filter(|f| f.severity == Severity::Error).count()
    }
    pub fn passes(&self) -> bool { self.errors() == 0 }
}

/// Human-readable policy locator. The IR doesn't carry source line
/// numbers, so the location is the policy name (and target domain
/// if cross-domain). If two nameless policies share a key this will
/// still be unique enough to act on — the emit/trigger pair already
/// identifies the clash.
fn locate(p: &Policy) -> String {
    match &p.target_domain {
        Some(d) if !d.is_empty() => format!("{}@{}", p.name, d),
        _                        => p.name.clone(),
    }
}

pub fn check(domain: &Domain) -> Report {
    let mut by_key: BTreeMap<(String, String), Vec<&Policy>> = BTreeMap::new();
    for p in &domain.policies {
        let key = (p.on_event.clone(), p.trigger_command.clone());
        by_key.entry(key).or_default().push(p);
    }

    let mut findings = Vec::new();
    for ((event, trigger), group) in &by_key {
        if group.len() < 2 { continue; }
        let names: Vec<String> = group.iter().map(|p| locate(p)).collect();
        let location = names.join(", ");
        findings.push(Finding::err(
            location,
            format!(
                "{} policies share (on: {:?}, trigger: {:?}) — the \
                 trigger fires once per matching policy, so {} will \
                 run {} times per {} event. Delete the duplicates or \
                 collapse them into one policy.",
                group.len(), event, trigger, trigger, group.len(), event,
            ),
        ));
    }
    Report { findings }
}
