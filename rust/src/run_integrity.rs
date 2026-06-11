//! Integrity — referential-integrity check over DECLARED cross-aggregate
//! references.
//!
//! Sibling of `validate` : `validate` checks the bluebook STRUCTURE, this
//! checks the live DATA against it. For every aggregate's dependent-side
//! reference (`belongs_to` / `has_one` / legacy `reference_to`), it reads
//! each record's stored foreign key and resolves it against the target
//! aggregate's records. Any FK that points at a record which does not exist
//! is a DANGLING reference — the silent-orphan class that severed 144 plan
//! stories from their sprints with no error.
//!
//! Scope (increment 1) : DECLARED references only. A bare String ref that
//! was never declared as a relationship (e.g. `Story.sprint` pre-Sprint-24)
//! is invisible here until it is typed as `belongs_to` — that is increment 2.
//! `has_many` is the owner side (no stored FK) and self-references (a command
//! naming its own aggregate) are skipped : neither stores a cross-aggregate FK.
//!
//! Usage:
//!   let dangling = run_integrity::check(&rt);
//!   assert!(dangling.is_empty());

use crate::ir::ReferenceKind;
use crate::runtime::Runtime;

/// One dangling cross-aggregate reference : `aggregate(record_id).field`
/// stores `value`, but no `target` record with that id exists.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Dangling {
    pub aggregate: String,
    pub record_id: String,
    pub field: String,
    pub target: String,
    pub value: String,
}

/// Walk every aggregate's declared dependent-side references and collect
/// every stored FK that does not resolve to an existing target record.
pub fn check(rt: &Runtime) -> Vec<Dangling> {
    let mut out = Vec::new();
    for agg in &rt.domain.aggregates {
        for r in &agg.references {
            // Only the dependent/single side stores an FK on the record.
            match r.kind {
                ReferenceKind::BelongsTo
                | ReferenceKind::HasOne
                | ReferenceKind::LegacyReferenceTo => {}
                ReferenceKind::HasMany => continue,
            }
            // A reference whose target IS the enclosing aggregate is a
            // command self-id (reference_to(Self)), not a cross-aggregate FK.
            if r.target == agg.name {
                continue;
            }
            let field = crate::util::snake_case(&r.name);
            for rec in rt.all(&agg.name) {
                // Only a non-empty scalar (Str / Int) is a resolvable FK.
                // Null, empty string, and list values (an unset reference
                // renders as an empty list) carry no target to resolve.
                let val = match rec.fields.get(&field) {
                    Some(crate::runtime::Value::Str(s)) if !s.is_empty() => s.clone(),
                    Some(crate::runtime::Value::Int(n)) => n.to_string(),
                    _ => continue,
                };
                if rt.find(&r.target, &val).is_none() {
                    out.push(Dangling {
                        aggregate: agg.name.clone(),
                        record_id: rec.id.clone(),
                        field: field.clone(),
                        target: r.target.clone(),
                        value: val,
                    });
                }
            }
        }
    }
    out
}
