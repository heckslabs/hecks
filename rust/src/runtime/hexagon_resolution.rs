//! Hexagon binding resolution — the typed attach checkpoint (bucket-3).
//! [antibody-exempt: rust/src/runtime/hexagon_resolution.rs — kernel-floor
//!  runtime resolver over the loaded Hecksagon IR ; inherently Rust, it
//!  realises Hexagon.Verify over framework-vocabulary IR (no bluebook
//!  projection of the resolver function itself)]
//!
//! Class:   hexagon_resolution
//! Purpose: realise `Hexagon.Verify` over the loaded `Vec<Hecksagon>` IR.
//!          A hexagon bind `aggregate.verb("Adapter")` resolves IFF the
//!          named adapter's family carries `verb` — the inverted arrow
//!          checked at wiring time (the grammar : Binding has_one Adapter,
//!          Adapter belongs_to Family, Family carries the how-verb ; "the
//!          how-verb is derived via the adapter's family").
//!
//! This is the IR-level realisation of the aggregate-modelled
//! `Hexagon.Verify` command : bindings / families / adapters are FIXED
//! framework vocabulary read as IR (bucket-3), not aggregate state, so the
//! check is a pure function over the loaded books rather than a dispatch.
//! Step 3 of lighting up `persisted_by` : parse (done) → RESOLVE (here) →
//! consult at dispatch (next). The dormant `framework_registry` is NOT
//! consulted — the resolver reads the loaded IR directly.
//!
//! Usage:
//!   let verdicts = resolve_bindings(&runtime.hecksagons);
//!   let broken: Vec<_> = verdicts.iter().filter(|r| !r.is_ok()).collect();

use crate::hecksagon_ir::Hecksagon;
use std::collections::HashMap;

/// The verdict for one binding's adapter→family→verb resolution.
#[derive(Debug, Clone, PartialEq)]
pub enum ResolveOutcome {
    /// The adapter is declared and its family carries the bind's verb.
    /// Carries the resolved family so the consult step reuses it without
    /// re-resolving.
    Resolved { family: String },
    /// A fulfillment bind (verb `on`) — routed cross-domain through
    /// storehouse ; it names no impure family, so there is no attach to
    /// check here. (No such bind exists in the corpus yet ; this keeps the
    /// resolver correct-by-construction if one appears.)
    Fulfillment,
    /// The bind names an adapter that no `.adapter` file declared.
    UnknownAdapter,
    /// The adapter's declared family was declared by no `.family` file.
    AdapterFamilyMissing { family: String },
    /// The adapter's family carries a DIFFERENT how-verb than the bind
    /// uses — the typed attach checkpoint failing loudly.
    VerbMismatch { family: String, family_verb: String },
}

/// One binding paired with its resolution verdict.
#[derive(Debug, Clone, PartialEq)]
pub struct BindingResolution {
    pub aggregate: String,
    pub verb: String,
    pub adapter: String,
    pub on: String,
    pub outcome: ResolveOutcome,
}

impl BindingResolution {
    /// True when the bind wired up cleanly (resolved through its family, or
    /// a fulfillment bind routed via storehouse).
    pub fn is_ok(&self) -> bool {
        matches!(
            self.outcome,
            ResolveOutcome::Resolved { .. } | ResolveOutcome::Fulfillment
        )
    }
}

/// Resolve every binding across the loaded hecksagons against the
/// flat-mapped adapters (name→family) and families (name→verb). THIS is
/// the typed attach checkpoint `Hexagon.Verify` names : a bind
/// `aggregate.verb("Adapter")` resolves IFF the named adapter's family
/// carries `verb`. Pure over the IR — no boot, no dispatch, no side-table.
pub fn resolve_bindings(hecksagons: &[Hecksagon]) -> Vec<BindingResolution> {
    let mut adapter_family: HashMap<&str, &str> = HashMap::new();
    let mut family_verb: HashMap<&str, &str> = HashMap::new();
    for hex in hecksagons {
        for a in &hex.adapters {
            adapter_family.insert(a.name.as_str(), a.family.as_str());
        }
        for f in &hex.families {
            family_verb.insert(f.name.as_str(), f.verb.as_str());
        }
    }

    let mut out = Vec::new();
    for hex in hecksagons {
        for b in &hex.bindings {
            let outcome = if b.verb == "on" {
                ResolveOutcome::Fulfillment
            } else {
                match adapter_family.get(b.adapter.as_str()) {
                    None => ResolveOutcome::UnknownAdapter,
                    Some(fam) => match family_verb.get(*fam) {
                        None => ResolveOutcome::AdapterFamilyMissing {
                            family: (*fam).to_string(),
                        },
                        Some(fv) if *fv == b.verb => ResolveOutcome::Resolved {
                            family: (*fam).to_string(),
                        },
                        Some(fv) => ResolveOutcome::VerbMismatch {
                            family: (*fam).to_string(),
                            family_verb: (*fv).to_string(),
                        },
                    },
                }
            };
            out.push(BindingResolution {
                aggregate: b.aggregate.clone(),
                verb: b.verb.clone(),
                adapter: b.adapter.clone(),
                on: b.on.clone(),
                outcome,
            });
        }
    }
    out
}
