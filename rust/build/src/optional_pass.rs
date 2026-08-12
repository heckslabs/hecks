//! A Rust port of `RustProjection::Projector.mark_append_optional_fields!`
//! (`rust/project/mutations.rb`), operating on the parsed `ir.json` tree
//! (`crate::json::Json`) rather than a live Ruby Hash. This is the ONE
//! genuinely new piece of DATA-TRANSFORM logic this crate ports — see
//! `rust/project_rust_pipeline.rb::derive_append_optionals`'s own header
//! for why it's still necessary even though `spec/codegen_parity_spec.rb`
//! found it a no-op against `hecks-codegen domain`'s own corpus fixture:
//! that spec builds its `ir.json` from Ruby's ALREADY-MUTATED Hash (Ruby's
//! `DomainGenerator.call` runs this same pass in-place before the spec
//! ever serializes it), so it never actually exercised codegen against
//! genuinely pre-derivation input the way this crate's own pipeline does.
//!
//! THE RULE (read directly off `mutations.rb`'s own `mark_append_
//! optional_fields!`/`append_element`/`append_field_source`, not
//! reinvented): for every attribute on an aggregate whose declared TYPE
//! resolves to a value object or an entity, look at every `append`
//! mutation any command on this aggregate targets at that attribute; for
//! every one of that mutation's own bound fields, if the field's SOURCE
//! is a command ARGUMENT (not a literal) and that argument is itself
//! `optional: true`, then the element's own field of the same name is
//! marked `optional: true` too — because Ruby's real `apply_mutations`
//! runs every declared mutation unconditionally, and a caller-omitted
//! optional argument arrives as a genuine `nil` that would otherwise
//! reach a Rust struct field typed as a bare (non-`Option`) value.
//!
//! WHICH WIRE VALUES COUNT AS "ARGUMENT-SOURCED": `IR::Mutation#to_h`'s
//! own `appended_fields` renders each append field's value through
//! `Hecksagain::Literal.render` (`lib/hecksagain/literal.rb`) — the ONE
//! pinned spelling for every captured Ruby literal on the wire. Of its
//! six cases, only `Symbol` (a command argument's own name) gets a
//! leading colon (`:#{value}`); every other case (`nil`, `true`/`false`,
//! a number, a quoted String, a brace-wrapped Hash, a bracket-wrapped
//! Array) is spelled some other way that can never start with `:`. So
//! "does this field's own wire text start with `:`" is the exact,
//! unambiguous inverse of `Marks.read(source).is_a?(Symbol)` — the
//! check `append_field_source`/`mark_append_optional_fields!` actually
//! make — without needing this crate to implement `Literal.read`'s full
//! grammar (hash/array/number/string literal parsing) for a fact this
//! one pass never otherwise needs. Confirmed live: banking's own
//! `Credit.ledger` append (`"amount": ":amount"`, `"direction":
//! "{value: \"credit\"}"`) shows both shapes in the same real mutation —
//! the argument-sourced field starts with `:`, the literal Hash field
//! starts with `{`.

use crate::json::Json;

/// `derive_append_optionals` (Ruby) top level — runs the pass over EVERY
/// aggregate in a chapter's `ir.json`, matching
/// `ir[:aggregates].each { |aggregate| mark_append_optional_fields!
/// (aggregate, value_objects_by_name) }` exactly (this Rust port
/// recomputes each aggregate's own value-object/entity lookup inline
/// rather than building the intermediate `value_objects_by_name` Hash —
/// same outcome, since Ruby's own Hash was only ever a name->object
/// index, never handed anywhere else).
pub fn run(ir: &mut Json) {
    if let Some(aggregates) = ir.get_mut("aggregates").and_then(Json::as_array_mut) {
        for aggregate in aggregates.iter_mut() {
            mark_append_optional_fields(aggregate);
        }
    }
}

enum ElementRef {
    ValueObject(usize),
    Entity(usize),
}

/// `append_element` (Ruby) — a plain value object OR an entity, resolved
/// by declared type name; value objects are checked first, matching
/// `value_objects_by_name.key?(target_type)`'s own priority (a name
/// cannot legally be both in one real aggregate, so order is never
/// actually load-bearing against real corpus, but this mirrors Ruby's
/// own branch order exactly regardless).
fn find_element_ref(aggregate: &Json, target_type: &str) -> Option<ElementRef> {
    if let Some(idx) = aggregate.get("value_objects").map(Json::each).unwrap_or(&[]).iter().position(|vo| vo.get("name").and_then(Json::as_str) == Some(target_type)) {
        return Some(ElementRef::ValueObject(idx));
    }
    if let Some(idx) = aggregate.get("entities").map(Json::each).unwrap_or(&[]).iter().position(|e| e.get("name").and_then(Json::as_str) == Some(target_type)) {
        return Some(ElementRef::Entity(idx));
    }
    None
}

/// One aggregate's own pass — `mark_append_optional_fields!` (Ruby),
/// restructured into two steps (gather, then apply) rather than Ruby's
/// single mutate-while-walking loop, because Rust's borrow checker
/// can't hold a mutable reference into `aggregate["value_objects"]`/
/// `aggregate["entities"]` at the same time as an immutable one into
/// `aggregate["commands"]` the way Ruby's shared-object-graph mutation
/// does implicitly. Behaviorally identical: nothing this pass WRITES
/// (`field_attr[:optional]`) is ever READ by this same pass (it only
/// reads `source_attr[:optional]`, a command argument, never a
/// value-object/entity field), so there is no ordering dependency
/// between the two steps to preserve.
fn mark_append_optional_fields(aggregate: &mut Json) {
    let target_attrs: Vec<(String, String)> = aggregate
        .get("attributes")
        .map(Json::each)
        .unwrap_or(&[])
        .iter()
        .filter_map(|a| {
            let name = a.get("name").and_then(Json::as_str)?;
            let type_name = a.get("type").and_then(Json::as_str)?;
            Some((name.to_string(), type_name.to_string()))
        })
        .collect();

    for (attr_name, attr_type) in target_attrs {
        let Some(element_ref) = find_element_ref(aggregate, &attr_type) else { continue };

        let fields_to_mark = collect_fields_to_mark(aggregate, &attr_name);
        if fields_to_mark.is_empty() {
            continue;
        }

        apply_marks(aggregate, &element_ref, &fields_to_mark);
    }
}

/// Every field name, across every command's every `append` mutation
/// targeting `target_attr_name`, whose own source is a command argument
/// that is itself `optional: true` — this pass's whole "which fields
/// need `Option<T>`" question, answered without mutating anything yet.
fn collect_fields_to_mark(aggregate: &Json, target_attr_name: &str) -> Vec<String> {
    let mut out = Vec::new();

    for command in aggregate.get("commands").map(Json::each).unwrap_or(&[]) {
        let command_attrs = command.get("attributes").map(Json::each).unwrap_or(&[]);

        for mutation in command.get("mutations").map(Json::each).unwrap_or(&[]) {
            let op = mutation.get("op").and_then(Json::as_str).unwrap_or("");
            let target = mutation.get("target").and_then(Json::as_str).unwrap_or("");
            if op != "append" || target != target_attr_name {
                continue;
            }

            let Some(fields) = mutation.get("fields").and_then(Json::as_object) else { continue };
            for (field_name, source) in fields {
                // A SYMBOL (an argument name) is the ONLY `Literal.render`
                // spelling that starts with `:` — see this module's own
                // header on why that's the exact, sufficient check.
                let Some(source_text) = source.as_str() else { continue };
                let Some(arg_name) = source_text.strip_prefix(':') else { continue };

                let source_is_optional = command_attrs.iter().any(|a| {
                    a.get("name").and_then(Json::as_str) == Some(arg_name) && a.get("optional").map(Json::as_bool).unwrap_or(false)
                });
                if source_is_optional {
                    out.push(field_name.clone());
                }
            }
        }
    }

    out
}

/// `field_attr[:optional] = true if field_attr` — applied to whichever
/// value-object or entity element `find_element_ref` resolved, by index
/// into `aggregate`'s own `value_objects`/`entities` array (never a
/// detached copy — the same in-place-mutation guarantee Ruby's shared
/// Hash graph gives for free).
fn apply_marks(aggregate: &mut Json, element_ref: &ElementRef, fields_to_mark: &[String]) {
    let element = match element_ref {
        ElementRef::ValueObject(idx) => aggregate.get_mut("value_objects").and_then(Json::as_array_mut).and_then(|v| v.get_mut(*idx)),
        ElementRef::Entity(idx) => aggregate.get_mut("entities").and_then(Json::as_array_mut).and_then(|v| v.get_mut(*idx)),
    };
    let Some(element) = element else { return };
    let Some(attrs) = element.get_mut("attributes").and_then(Json::as_array_mut) else { return };

    for field_name in fields_to_mark {
        if let Some(field_attr) = attrs.iter_mut().find(|a| a.get("name").and_then(Json::as_str) == Some(field_name.as_str())) {
            field_attr.set_bool("optional", true);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A minimal stand-in for banking's own `Account.Credit` shape: a
    /// list attribute `ledger` of entity type `LedgerEntry`, one
    /// `append` mutation binding `amount` from the command's own
    /// `amount` argument (declared `optional: true`) and `direction`
    /// from a literal Hash — the same two shapes the real corpus's
    /// `Credit`/`Debit` mutations show side by side.
    fn fixture() -> Json {
        Json::parse(
            r#"{
  "attributes": [
    {"name": "ledger", "type": "LedgerEntry", "list": true, "default": null, "optional": false, "pattern": null, "admits": null}
  ],
  "value_objects": [],
  "entities": [
    {
      "name": "LedgerEntry",
      "attributes": [
        {"name": "amount", "type": "Money", "list": false, "default": null, "optional": false, "pattern": null, "admits": null},
        {"name": "direction", "type": "Direction", "list": false, "default": null, "optional": false, "pattern": null, "admits": null}
      ]
    }
  ],
  "commands": [
    {
      "name": "Credit",
      "attributes": [
        {"name": "amount", "type": "PositiveMoney", "list": false, "default": null, "optional": true, "pattern": null, "admits": null}
      ],
      "mutations": [
        {"target": "ledger", "op": "append", "fields": {"amount": ":amount", "direction": "{value: \"credit\"}"}}
      ]
    }
  ]
}"#,
        )
        .expect("fixture parses")
    }

    #[test]
    fn marks_the_argument_sourced_field_optional() {
        let mut aggregate = fixture();
        mark_append_optional_fields(&mut aggregate);

        let entity = &aggregate.get("entities").unwrap().each()[0];
        let amount = entity.get("attributes").unwrap().each().iter().find(|a| a.get("name").and_then(Json::as_str) == Some("amount")).unwrap();
        assert!(amount.get("optional").unwrap().as_bool());
    }

    #[test]
    fn leaves_the_literal_sourced_field_alone() {
        let mut aggregate = fixture();
        mark_append_optional_fields(&mut aggregate);

        let entity = &aggregate.get("entities").unwrap().each()[0];
        let direction = entity.get("attributes").unwrap().each().iter().find(|a| a.get("name").and_then(Json::as_str) == Some("direction")).unwrap();
        assert!(!direction.get("optional").map(Json::as_bool).unwrap_or(false));
    }

    #[test]
    fn leaves_a_non_optional_source_argument_alone() {
        let mut aggregate = fixture();
        // Flip the command argument to non-optional and confirm nothing
        // gets marked — the pass's own negative case.
        let command = &mut aggregate.get_mut("commands").unwrap().as_array_mut().unwrap()[0];
        let arg = &mut command.get_mut("attributes").unwrap().as_array_mut().unwrap()[0];
        arg.set_bool("optional", false);

        mark_append_optional_fields(&mut aggregate);

        let entity = &aggregate.get("entities").unwrap().each()[0];
        let amount = entity.get("attributes").unwrap().each().iter().find(|a| a.get("name").and_then(Json::as_str) == Some("amount")).unwrap();
        assert!(!amount.get("optional").map(Json::as_bool).unwrap_or(false));
    }
}
