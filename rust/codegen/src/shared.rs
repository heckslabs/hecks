//! Predicates ported from the retired Ruby generator's `mutations.rb` that `types.rs` and `json_codec.rs` share.

use crate::json::Json;
use std::collections::HashMap;

/// Argument names claimed by an append, so an append's element-field argument never bare-name-
/// matches an unrelated owner field. Shared by `creates_owner` and `identity_components`.
pub fn append_claimed_names(command: &Json) -> std::collections::HashSet<String> {
    let mut claimed = std::collections::HashSet::new();
    for m in command.get("mutations").map_or_default(Json::each) {
        if m.get("op").map(Json::to_s).as_deref() != Some("append") {
            continue;
        }
        if let Some(Json::Object(pairs)) = m.get("fields") {
            for (_, wire_value) in pairs {
                let literal = crate::literal::read(wire_value.as_str().unwrap_or(""));
                if let crate::literal::Literal::Symbol(s) = literal {
                    claimed.insert(s);
                }
            }
        }
    }
    claimed
}

/// Whether `command` builds the owner record from scratch (`mutations.rb#creates_owner?`).
///
/// A command with `references` acts on an existing record. Otherwise it creates when it supplies,
/// via a `:set` mutation or a same-named argument, a required non-list owner field, ignoring
/// arguments claimed by an append (`append_claimed_names`).
pub fn creates_owner(
    aggregate: &Json,
    command: &Json,
    _value_objects_by_name: &HashMap<String, &Json>,
) -> bool {
    if command.get("references").is_some() {
        return false;
    }

    let attrs = aggregate.get("attributes").map_or_default(Json::each);
    let owner_fields: std::collections::HashSet<String> = attrs
        .iter()
        .map(|a| crate::attr::name(a).to_string())
        .collect();
    let required_fields: std::collections::HashSet<String> = attrs
        .iter()
        .filter(|a| !crate::attr::list(a) && !crate::attr::optional(a))
        .map(|a| crate::attr::name(a).to_string())
        .collect();

    let append_claimed = append_claimed_names(command);

    let mut known_writes: std::collections::HashSet<String> = std::collections::HashSet::new();
    for attr in command.get("attributes").map_or_default(Json::each) {
        let name = crate::attr::name(attr).to_string();
        if owner_fields.contains(&name) && !append_claimed.contains(&name) {
            known_writes.insert(name);
        }
    }
    for m in command.get("mutations").map_or_default(Json::each) {
        if m.get("op").map(Json::to_s).as_deref() != Some("set") {
            continue;
        }
        let target = m.get("target").map(Json::to_s).unwrap_or_default();
        if owner_fields.contains(&target) {
            known_writes.insert(target);
        }
    }

    required_fields
        .iter()
        .any(|field| known_writes.contains(field))
}

/// Whether a list-typed attribute reads `nil` rather than `[]` in Ruby; see
/// `mutations.rb#list_attr_creation_optional?`.
pub fn list_attr_creation_optional(
    aggregate: &Json,
    attr_name: &str,
    value_objects_by_name: &HashMap<String, &Json>,
) -> bool {
    let commands = aggregate.get("commands").map_or_default(Json::each);
    commands.iter().any(|command| {
        if !creates_owner(aggregate, command, value_objects_by_name) {
            return false;
        }
        let mutations = command.get("mutations").map_or_default(Json::each);
        mutations.iter().any(|m| {
            let op = m.get("op").map(Json::to_s).unwrap_or_default();
            let target = m.get("target").map(Json::to_s).unwrap_or_default();
            if op != "set" || target != attr_name {
                return false;
            }
            let Some(source) = m.get("source") else {
                return false;
            };
            if source.get("kind").map(Json::to_s).unwrap_or_default() != "argument" {
                return false;
            }
            let source_name = source.get("name").map(Json::to_s).unwrap_or_default();
            let attrs = command.get("attributes").map_or_default(Json::each);
            attrs
                .iter()
                .find(|a| crate::attr::name(a) == source_name)
                .is_some_and(crate::attr::optional)
        })
    })
}
