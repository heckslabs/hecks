//! Resolution of a policy's `ask :name` to the port operation the hecksagon declared for it,
//! mirroring `Hecks::Bluebook::AskResolution`: by the event's aggregate and the ask's name, with
//! `chosen` (`ask_via`) breaking a tie between ports.

use crate::json::Json;
use crate::naming;

/// Policies whose `ask` is replaced by the `Aggregate::Port.Operation` trigger it resolves to,
/// so every table below reads the verb as it reads a port-naming `trigger`.
///
/// Panics when an ask resolves to nothing or to several operations: the Ruby boot refuses both
/// before the IR is ever exported.
pub fn resolve_asks(policies: &[Json], aggregates: &[Json]) -> Vec<Json> {
    policies
        .iter()
        .map(|policy| match policy.get("ask").map(Json::to_s) {
            Some(ask) if !ask.is_empty() => with_trigger(policy, resolve(policy, &ask, aggregates)),
            _ => policy.clone(),
        })
        .collect()
}

fn with_trigger(policy: &Json, verb: String) -> Json {
    let mut resolved = policy.clone();
    resolved.set("trigger_command", Json::String(verb));
    resolved
}

fn resolve(policy: &Json, ask: &str, aggregates: &[Json]) -> String {
    let name = policy.get("name").map(Json::to_s).unwrap_or_default();
    let on_event = policy.get("on_event").map(Json::to_s).unwrap_or_default();
    let aggregate = event_aggregate(&on_event, aggregates)
        .unwrap_or_else(|| panic!("policy {name}: ask :{ask} reacts to {on_event:?}, whose aggregate is not declared"));
    let agg_name = aggregate.get("name").map(Json::to_s).unwrap_or_default();
    let mut found = candidates(aggregate, ask);
    if found.len() > 1 && found.iter().any(|(_, op)| op.get("chosen").is_some_and(Json::as_bool)) {
        found.retain(|(_, op)| op.get("chosen").is_some_and(Json::as_bool));
    }
    match found.as_slice() {
        [(port, op)] => format!("{agg_name}::{port}.{}", op.get("name").map(Json::to_s).unwrap_or_default()),
        [] => panic!("policy {name}: ask :{ask} matches no `asks` declared on {agg_name}"),
        _ => panic!("policy {name}: ask :{ask} is asked on several ports of {agg_name}; pick one with ask_via"),
    }
}

// The aggregate the event is qualified with, or else the one whose commands emit the bare event.
fn event_aggregate<'a>(on_event: &str, aggregates: &'a [Json]) -> Option<&'a Json> {
    let named = |wanted: &str| aggregates.iter().find(|a| a.get("name").map(Json::to_s).unwrap_or_default() == wanted);
    match on_event.split_once('.') {
        Some((qualifier, _)) => named(qualifier.rsplit("::").next().unwrap_or(qualifier)),
        None => aggregates.iter().find(|a| {
            a.get("commands")
                .map(Json::each)
                .unwrap_or(&[])
                .iter()
                .any(|c| c.get("emits").map(Json::to_s).unwrap_or_default() == on_event)
        }),
    }
}

// Every outbound operation of the aggregate's ports whose snake-cased name is the ask.
fn candidates<'a>(aggregate: &'a Json, ask: &str) -> Vec<(String, &'a Json)> {
    let mut found = Vec::new();
    for port in aggregate.get("ports").map(Json::each).unwrap_or(&[]) {
        let port_name = port.get("name").map(Json::to_s).unwrap_or_default();
        for op in port.get("operations").map(Json::each).unwrap_or(&[]) {
            let outbound = op.get("direction").map(Json::to_s).as_deref() == Some("outbound");
            let spelled = naming::snake(&op.get("name").map(Json::to_s).unwrap_or_default());
            if outbound && spelled == ask {
                found.push((port_name.clone(), op));
            }
        }
    }
    found
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    // The neutral corpus fixture `spec/corpus/asks/errand.json`: the Ruby spec holds the same
    // `targets` against the Ruby runtime's reaction log, so the two cannot drift.
    fn corpus(name: &str) -> Json {
        let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../spec/corpus/asks").join(name);
        Json::parse(&std::fs::read_to_string(path).expect("corpus file")).expect("corpus json")
    }

    #[test]
    fn every_ask_resolves_to_the_target_the_corpus_freezes() {
        let ir = corpus("errand.ir.json");
        let expect = corpus("errand.json");
        let domain = ir.get("name").map(Json::to_s).unwrap_or_default();
        let resolved = resolve_asks(ir.get("policies").unwrap().each(), ir.get("aggregates").unwrap().each());

        for policy in &resolved {
            let name = policy.get("name").map(Json::to_s).unwrap_or_default();
            let target = format!("{domain}::{}", policy.get("trigger_command").map(Json::to_s).unwrap_or_default());
            let frozen = expect.get("targets").and_then(|t| t.get(&name)).map(Json::to_s);
            assert_eq!(frozen, Some(target), "{name}");
        }
    }
}
