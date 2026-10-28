//! Rust port of `Exporter::Bindings` (`lib/hecks/projector/exporter/bindings.rb`) and the provider
//! lookups of `Registry::Providers`: which attached bluebook answers each capability the target
//! domain uses, read from every bluebook's own `provides` entries in its IR.

use crate::json::Json;

/// One capability the language defines that `rust/host` reads: the keys it exports as qualified
/// verbs, then each derived `name => verb key` aggregate, in the order `Bindings` builds them.
struct Seam {
    capability: &'static str,
    verbs: &'static [&'static str],
    aggregates: &'static [(&'static str, &'static str)],
}

// In `TargetIr::SEAMS` order, which is the order the keys land in `ir.json`.
const SEAMS: &[Seam] = &[
    Seam {
        capability: "authorization",
        verbs: &["grant", "assignments", "live_assignments"],
        aggregates: &[("assignment_aggregate", "assignments")],
    },
    Seam {
        capability: "membership",
        verbs: &["admit", "grant", "people"],
        aggregates: &[("aggregate", "admit")],
    },
    Seam {
        capability: "identity",
        verbs: &["register", "link", "resolve"],
        aggregates: &[],
    },
];

/// Every capability the language defines a contract for (`Capabilities::CONTRACTS`); any other
/// `provides` name is a package's own and exports through `provides`.
const LANGUAGE_DEFINED: &[&str] = &[
    "authorization",
    "membership",
    "identity",
    "privacy",
    "subject_keys",
];

/// Sets each seam some bluebook provides on `target`, leaving it out otherwise, as
/// `TargetIr#add_seams` does, then the `provides` map of every capability a package declares.
/// `members` are the bluebooks the target attaches, in attach order; the target itself is searched
/// first.
pub fn run(target: &mut Json, members: &[Json]) -> Result<(), String> {
    let mut declarations: Vec<Json> = vec![target.clone()];
    declarations.extend(members.iter().cloned());

    let mut membership = false;
    let mut identity = false;
    for seam in SEAMS {
        let Some(provider) = provider_of(&declarations, seam.capability) else {
            continue;
        };
        membership |= seam.capability == "membership";
        identity |= seam.capability == "identity";
        target.set(seam.capability, export(seam, provider));
    }
    if membership && !identity {
        return Err(format!(
            "{} provides membership but not identity — rust/host Google sign-in cannot register or link an identity from ir.json. \
             Attach Identity so the hecksagon, not a deploy-time guess, names the identity verbs.",
            name_of(target)
        ));
    }
    let provided = package_provides(&declarations);
    if matches!(&provided, Json::Object(entries) if !entries.is_empty()) {
        target.set("provides", provided);
    }
    Ok(())
}

fn provider_of<'a>(declarations: &'a [Json], capability: &str) -> Option<&'a Json> {
    declarations
        .iter()
        .find(|declaration| provision(declaration, capability).is_some())
}

fn export(seam: &Seam, provider: &Json) -> Json {
    let name = name_of(provider);
    let entries = provision(provider, seam.capability).unwrap_or_default();
    let verb = |key: &str| {
        entries
            .iter()
            .find(|(k, _)| k == key)
            .map(|(_, v)| format!("{name}::{v}"))
    };

    let mut out = vec![("provider".to_string(), Json::String(name.clone()))];
    for key in seam.verbs {
        out.push((key.to_string(), verb(key).map_or(Json::Null, Json::String)));
    }
    for (exported, key) in seam.aggregates {
        let aggregate = verb(key).map(|v| v.split('.').next().unwrap_or_default().to_string());
        out.push((
            exported.to_string(),
            aggregate.map_or(Json::Null, Json::String),
        ));
    }
    Json::Object(out)
}

/// `Exporter.provides`: each package-declared capability, sorted by name, as its provider resolves
/// every key (`Capabilities.resolved_value`).
fn package_provides(declarations: &[Json]) -> Json {
    let mut capabilities: Vec<String> = declarations
        .iter()
        .flat_map(|declaration| declaration.get("provides").map_or(&[][..], Json::each).iter())
        .filter_map(|entry| entry.get("capability").and_then(Json::as_str))
        .filter(|capability| !LANGUAGE_DEFINED.contains(capability))
        .map(str::to_string)
        .collect();
    capabilities.sort();
    capabilities.dedup();

    let exported = capabilities
        .into_iter()
        .filter_map(|capability| {
            let provider = provider_of(declarations, &capability)?;
            let name = name_of(provider);
            let mut out = vec![("provider".to_string(), Json::String(name.clone()))];
            for (key, verb) in provision(provider, &capability).unwrap_or_default() {
                out.push((key, resolved_value(provider, &name, &verb)));
            }
            Some((capability, Json::Object(out)))
        })
        .collect();
    Json::Object(exported)
}

/// What a package-declared key's target resolves to: a lifecycle mark's states, an attribute's
/// `{ attribute, default }`, or else the qualified verb of a command, query or port operation. The
/// Ruby builder has already refused a target that names nothing or more than one kind.
fn resolved_value(provider: &Json, name: &str, verb: &str) -> Json {
    let Some((aggregate_name, member)) = verb.split_once('.') else {
        return Json::String(format!("{name}::{verb}"));
    };
    let aggregate = provider
        .get("aggregates")
        .map_or(&[][..], Json::each)
        .iter()
        .find(|a| a.get("name").and_then(Json::as_str) == Some(aggregate_name));
    if let Some(aggregate) = aggregate.filter(|_| !member.contains('.')) {
        if let Some(states) = aggregate
            .get("lifecycle")
            .and_then(|l| l.get("marks"))
            .and_then(|marks| marks.get(member))
        {
            return states.clone();
        }
        if let Some(attribute) = aggregate
            .get("attributes")
            .map_or(&[][..], Json::each)
            .iter()
            .find(|a| a.get("name").and_then(Json::as_str) == Some(member))
        {
            return Json::Object(vec![
                ("attribute".to_string(), Json::String(member.to_string())),
                (
                    "default".to_string(),
                    filled_default(attribute.get("default")),
                ),
            ]);
        }
    }
    Json::String(format!("{name}::{verb}"))
}

/// An attribute's `default:` as the reader sees it: a one-field value object's `{ value: ... }` fill
/// unwrapped, as `Capabilities::AttributeValues#filled_value` does.
fn filled_default(default: Option<&Json>) -> Json {
    match default {
        Some(object @ Json::Object(_)) => object.get("value").cloned().unwrap_or(Json::Null),
        Some(value) => value.clone(),
        None => Json::Null,
    }
}

// `[(key, verb)]` this bluebook provides under `capability`, or `None` when it provides none.
fn provision(declaration: &Json, capability: &str) -> Option<Vec<(String, String)>> {
    let entries: Vec<(String, String)> = declaration
        .get("provides")
        .map_or(&[][..], Json::each)
        .iter()
        .filter(|entry| entry.get("capability").and_then(Json::as_str) == Some(capability))
        .filter_map(|entry| {
            Some((
                entry.get("key")?.as_str()?.to_string(),
                entry.get("verb")?.as_str()?.to_string(),
            ))
        })
        .collect();
    (!entries.is_empty()).then_some(entries)
}

fn name_of(declaration: &Json) -> String {
    declaration
        .get("name")
        .and_then(Json::as_str)
        .unwrap_or_default()
        .to_string()
}
