//! One function ported out of `rust/project/mutations.rb` early — used by
//! BOTH `types.rb`'s `emit_record` and `json_codec.rb`'s `emit_to_json_flat`
//! /`emit_from_json_state`, so it lives here rather than being duplicated.
//! `mutations.rb` itself (the command-mutation codegen this stage does not
//! port — see the report) is NOT ported; only this one self-contained
//! predicate, whose only real dependency is `aggregate[:commands]`'s shape
//! as already present in ir.json, moved over.

use crate::json::Json;

/// A list-typed aggregate attribute reads `nil` in Ruby, not `[]`, under
/// one precise condition — see `mutations.rb#list_attr_creation_optional?`'s
/// own header for the full argument. Mirrored directly here.
pub fn list_attr_creation_optional(aggregate: &Json, attr_name: &str) -> bool {
    let commands = aggregate.get("commands").map(Json::each).unwrap_or(&[]);
    commands.iter().any(|command| {
        // `next false unless command[:references].nil?` — creating only.
        if command.get("references").is_some() {
            return false;
        }
        let mutations = command.get("mutations").map(Json::each).unwrap_or(&[]);
        mutations.iter().any(|m| {
            let op = m.get("op").map(Json::to_s).unwrap_or_default();
            let target = m.get("target").map(Json::to_s).unwrap_or_default();
            if op != "set" || target != attr_name {
                return false;
            }
            let source = match m.get("source") {
                Some(s) => s,
                None => return false,
            };
            if source.get("kind").map(Json::to_s).unwrap_or_default() != "argument" {
                return false;
            }
            let source_name = source.get("name").map(Json::to_s).unwrap_or_default();
            let attrs = command.get("attributes").map(Json::each).unwrap_or(&[]);
            match attrs.iter().find(|a| crate::attr::name(a) == source_name) {
                Some(source_attr) => crate::attr::optional(source_attr),
                None => false,
            }
        })
    })
}
