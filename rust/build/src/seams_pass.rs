//! Rust port of `Exporter::Bindings` (`lib/hecks/projector/exporter/bindings.rb`) and the provider
//! lookups of `Registry::Providers`: which attached chapter answers each capability the target
//! domain uses, read from every chapter's own `provides` entries in its IR.

use crate::json::Json;

/// One capability's exported shape: the keys it exports as qualified verbs, then each derived
/// `name => verb key` aggregate, in the order `Bindings` builds them, then its optional marks.
struct Seam {
    capability: &'static str,
    export_as: &'static str,
    verbs: &'static [&'static str],
    aggregates: &'static [(&'static str, &'static str)],
    marks: &'static [&'static str],
}

// In `TargetIr::SEAMS` order, which is the order the keys land in `ir.json`.
const SEAMS: &[Seam] = &[
    Seam { capability: "authorization", export_as: "authorization", verbs: &["grant", "assignments"], aggregates: &[("assignment_aggregate", "assignments")], marks: &[] },
    Seam { capability: "membership", export_as: "membership", verbs: &["admit", "grant", "people"], aggregates: &[("aggregate", "admit")], marks: &[] },
    Seam { capability: "identity", export_as: "identity", verbs: &["register", "link", "resolve"], aggregates: &[], marks: &[] },
    Seam {
        capability: "newsletter",
        export_as: "newsletter",
        verbs: &["subscribe", "add_name", "confirm", "unsubscribe"],
        aggregates: &[("aggregate", "subscribe")],
        marks: &["awaiting_confirmation", "receives_issues", "left"],
    },
    Seam {
        capability: "newsletter_issues",
        export_as: "newsletter_issues",
        verbs: &["send_issue", "record_delivery"],
        aggregates: &[("issue_aggregate", "send_issue"), ("delivery_aggregate", "record_delivery")],
        marks: &[],
    },
    Seam { capability: "payments", export_as: "payments", verbs: &["initiate", "succeeded", "failed"], aggregates: &[("aggregate", "initiate")], marks: &["holds_seat"] },
    Seam {
        capability: "registrations",
        export_as: "registrations",
        verbs: &["schedule", "request"],
        aggregates: &[("event_aggregate", "schedule"), ("registration_aggregate", "request")],
        marks: &[],
    },
    Seam {
        capability: "payment_connection",
        export_as: "payment_connection",
        verbs: &["connect", "reconnect", "disconnect", "suspend", "resume", "enable", "disable"],
        aggregates: &[("aggregate", "connect")],
        marks: &[],
    },
];

/// Sets each seam some chapter provides on `target`, leaving it out otherwise, as
/// `TargetIr#add_seams` does. `members` are the chapters the target attaches, in attach order; the
/// target itself is searched first.
pub fn run(target: &mut Json, members: &[Json]) -> Result<(), String> {
    let mut chapters: Vec<Json> = vec![target.clone()];
    chapters.extend(members.iter().cloned());

    let mut membership = false;
    let mut identity = false;
    for seam in SEAMS {
        let Some(provider) = chapters.iter().find(|chapter| provision(chapter, seam.capability).is_some()) else { continue };
        let exported = export(seam, provider);
        membership |= seam.capability == "membership";
        identity |= seam.capability == "identity";
        target.set(seam.export_as, exported);
    }
    if membership && !identity {
        return Err(format!(
            "{} provides membership but not identity — rust/host Google sign-in cannot register or link an identity from ir.json. \
             Attach Identity so the hecksagon, not a deploy-time guess, names the identity verbs.",
            name_of(target)
        ));
    }
    Ok(())
}

fn export(seam: &Seam, provider: &Json) -> Json {
    let name = name_of(provider);
    let entries = provision(provider, seam.capability).unwrap_or_default();
    let verb = |key: &str| entries.iter().find(|(k, _)| k == key).map(|(_, v)| format!("{name}::{v}"));

    let mut out = vec![("provider".to_string(), Json::String(name.clone()))];
    for key in seam.verbs {
        out.push((key.to_string(), verb(key).map_or(Json::Null, Json::String)));
    }
    for (exported, key) in seam.aggregates {
        let aggregate = verb(key).map(|v| v.split('.').next().unwrap_or_default().to_string());
        out.push((exported.to_string(), aggregate.map_or(Json::Null, Json::String)));
    }
    for key in seam.marks {
        if let Some(states) = marked_states(provider, entries.iter().find(|(k, _)| k == key).map(|(_, v)| v.as_str())) {
            out.push((key.to_string(), states));
        }
    }
    Json::Object(out)
}

// `[(key, verb)]` this chapter provides under `capability`, or `None` when it provides none.
fn provision(chapter: &Json, capability: &str) -> Option<Vec<(String, String)>> {
    let entries: Vec<(String, String)> = chapter
        .get("provides")
        .map(Json::each)
        .unwrap_or(&[])
        .iter()
        .filter(|entry| entry.get("capability").and_then(Json::as_str) == Some(capability))
        .filter_map(|entry| Some((entry.get("key")?.as_str()?.to_string(), entry.get("verb")?.as_str()?.to_string())))
        .collect();
    (!entries.is_empty()).then_some(entries)
}

// The states of the aggregate lifecycle mark a `"Aggregate.mark"` entry names; `None` when the
// entry is not declared or the mark is.
fn marked_states(provider: &Json, entry: Option<&str>) -> Option<Json> {
    let (aggregate_name, mark) = entry?.split_once('.')?;
    let aggregate = provider.get("aggregates").map(Json::each)?.iter().find(|a| a.get("name").and_then(Json::as_str) == Some(aggregate_name))?;
    aggregate.get("lifecycle")?.get("marks")?.get(mark).cloned()
}

fn name_of(chapter: &Json) -> String {
    chapter.get("name").and_then(Json::as_str).unwrap_or_default().to_string()
}
