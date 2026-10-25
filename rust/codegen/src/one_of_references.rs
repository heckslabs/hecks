//! Reference checks for a tagged `reference_to one_of(A, B), as: :subject` (ADR 0122): the
//! aggregate attribute carries the `one_of` relationship, its type is the tagged value object
//! (`type` + `id`), and the value object's `type` admits the closed set of the variants' names.
//! A command that `sets` the attribute from an argument gets one check per variant, run only
//! when the argument's `type` names it, mirroring `CommandRules::OneOfReferences`.

use std::collections::HashMap;

use crate::json::Json;
use crate::registry::ReferenceCheck;

/// The variants a tagged reference may point at, read off its value objects; empty when the
/// shapes are missing.
fn variants(aggregate: &Json, tagged_type: &str) -> Vec<String> {
    let value_objects = aggregate.get("value_objects").map_or_default(Json::each);
    let named = |name: &str| {
        value_objects
            .iter()
            .find(|vo| vo.get("name").and_then(Json::as_str) == Some(name))
    };
    let admits = named(tagged_type)
        .map(|vo| vo.get("attributes").map_or_default(Json::each))
        .and_then(|attrs| {
            attrs
                .iter()
                .find(|a| crate::attr::name(a) == "type")
                .and_then(|a| a.get("admits").and_then(Json::as_str).map(str::to_string))
        });
    let Some(set) = admits
        .as_deref()
        .and_then(|a| named(a.rsplit("::").next().unwrap_or(a)))
    else {
        return Vec::new();
    };
    set.get("members")
        .map_or_default(Json::each)
        .iter()
        .filter_map(|member| {
            member.each().iter().find_map(|pair| {
                let pair = pair.each();
                (pair.first().and_then(Json::as_str) == Some("value"))
                    .then(|| pair.get(1).map(Json::to_s))
                    .flatten()
            })
        })
        .collect()
}

/// The argument a command `sets` an aggregate attribute from, if it does.
fn source_argument<'a>(command: &'a Json, attr_name: &str) -> Option<&'a Json> {
    let source_name = command
        .get("mutations")
        .map_or_default(Json::each)
        .iter()
        .find(|m| {
            m.get("op").map(Json::to_s).as_deref() == Some("set")
                && m.get("target").map(Json::to_s).as_deref() == Some(attr_name)
        })?
        .get("source")
        .filter(|s| s.get("kind").map(Json::to_s).as_deref() == Some("argument"))?
        .get("name")
        .map(Json::to_s)?;
    command
        .get("attributes")?
        .as_array()?
        .iter()
        .find(|a| crate::attr::name(a) == source_name)
}

/// One check per variant of every tagged reference `command` sets from an argument.
pub fn checks(
    aggregate: &Json,
    command: &Json,
    aggregates_by_name: &HashMap<String, &Json>,
    unsupported_names: &[String],
) -> Vec<ReferenceCheck> {
    let attrs = aggregate.get("attributes").map_or_default(Json::each);
    let mut out = Vec::new();
    for attr in attrs
        .iter()
        .filter(|a| a.get("relationship").and_then(Json::as_str) == Some("one_of"))
    {
        let Some(source) = source_argument(command, crate::attr::name(attr)) else {
            continue;
        };
        for variant in variants(aggregate, crate::attr::type_name(attr)) {
            if let Some(check) =
                variant_check(source, &variant, aggregates_by_name, unsupported_names)
            {
                out.push(check);
            }
        }
    }
    out
}

/// The check for one variant, or `None` when its aggregate is not generated.
fn variant_check(
    source: &Json,
    variant: &str,
    aggregates_by_name: &HashMap<String, &Json>,
    unsupported_names: &[String],
) -> Option<ReferenceCheck> {
    let target = aggregates_by_name.get(variant)?;
    if unsupported_names.iter().any(|n| n == variant) {
        return None;
    }
    let heads = target
        .get("identified_by")
        .map_or_default(Json::each)
        .iter()
        .map(|p| p.to_s().split('.').next().unwrap_or("").to_string())
        .collect::<Vec<_>>()
        .join(", ");
    Some(ReferenceCheck {
        field: crate::attr::name(source).to_string(),
        optional: crate::attr::optional(source),
        list_item: None,
        union_tag: Some(variant.to_string()),
        target_mod: crate::naming::aggregate_module(variant),
        target_name: variant.to_string(),
        heads,
    })
}
