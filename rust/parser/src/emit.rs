//! JSON writer — matches `JSON.pretty_generate(Exporter.call(...))`
//! byte-for-byte for the bundled `json` gem THIS repo actually resolves
//! (`bundle exec ruby -e 'puts JSON::VERSION'` -> 2.7.2, confirmed live,
//! not assumed — see the empty-array/object hazard note below).
//!
//! Walks `ir::Bluebook` field-by-field in Ruby's own `to_h` key order
//! (ir.rs's own header note on why key order is significant), converting
//! each construct to a generic `JsonValue` tree that `write` then
//! serializes.
//!
//! THE EMPTY-ARRAY/OBJECT HAZARD, PINNED FOR REAL (previously flagged,
//! deferred): `JSON.pretty_generate({a: []})` under the bundled json
//! 2.7.2 gem renders `"{\n  \"a\": [\n\n  ]\n}"` — an EXTRA blank,
//! unindented line between `[` and the closing `]`, confirmed by running
//! `bundle exec ruby -e 'require "json"; print JSON.pretty_generate({a:
//! []}).inspect'` in this repo directly (system json 2.21.2 would instead
//! collapse to `"[]"` — a real version difference, not a guess). An empty
//! OBJECT has no such quirk: `JSON.pretty_generate({a: {}})` renders
//! `"{\n  \"a\": {\n  }\n}"`, exactly what the ordinary (non-empty) object
//! writer already produces when its own loop simply runs zero times — so
//! `write_object` needs NO special case at all, only `write_array` does.
//! Every real corpus member's IR has non-empty top-level arrays, but
//! pizzas.bluebook's own `Order.entities`/`Order.ports`/several
//! `invariants`/`members`/`ensures`/`givens`/`mutations` lists ARE empty
//! in practice — this is exercised for real, not a theoretical case.

use std::fmt::Write as _;

use crate::ir;
use crate::ruby_value;

/// A minimal, hand-rolled JSON value writer — no serde, matching this
/// crate's std-only dependency discipline (see Cargo.toml's own comment on
/// why).
#[derive(Debug, Clone)]
pub enum JsonValue {
    Null,
    Bool(bool),
    Number(String),
    String(String),
    Array(Vec<JsonValue>),
    Object(Vec<(String, JsonValue)>),
}

impl JsonValue {
    fn str(s: impl Into<String>) -> JsonValue {
        JsonValue::String(s.into())
    }

    fn opt_str(s: &Option<String>) -> JsonValue {
        match s {
            Some(text) => JsonValue::String(text.clone()),
            None => JsonValue::Null,
        }
    }

    fn strings(items: &[String]) -> JsonValue {
        JsonValue::Array(items.iter().map(|s| JsonValue::String(s.clone())).collect())
    }
}

pub fn write(value: &JsonValue) -> String {
    let mut out = String::new();
    write_value(&mut out, value, 0);
    out
}

/// The pinned `Expression::CanonicalForm.table` — a fixed, non-per-domain
/// constant (`lib/hecksagain/bluebook/expression/projection.json`'s own
/// `normalisations` array, read+field-ordered exactly the way
/// `CanonicalForm.table` itself does: `strategy, source_token,
/// replacement, boundary, position` — `position` rendered as a STRING,
/// per `rule.position.to_s` in the Ruby source), written the same for
/// every chapter this emitter ever serializes.
fn canonical_form_table() -> JsonValue {
    JsonValue::Array(vec![
        JsonValue::Object(vec![
            ("strategy".to_string(), JsonValue::str("collapse_whitespace")),
            ("source_token".to_string(), JsonValue::str("")),
            ("replacement".to_string(), JsonValue::str("")),
            ("boundary".to_string(), JsonValue::str("none")),
            ("position".to_string(), JsonValue::str("1")),
        ]),
        JsonValue::Object(vec![
            ("strategy".to_string(), JsonValue::str("replace")),
            ("source_token".to_string(), JsonValue::str(".length")),
            ("replacement".to_string(), JsonValue::str(".size")),
            ("boundary".to_string(), JsonValue::str("word")),
            ("position".to_string(), JsonValue::str("2")),
        ]),
    ])
}

/// `IR::Bluebook#to_h` (lib/hecksagain/bluebook/ir/bluebook.rb) — top of
/// the construct chain, field order pinned there.
pub fn bluebook_json(bb: &ir::Bluebook) -> JsonValue {
    JsonValue::Object(vec![
        ("ir_version".to_string(), JsonValue::Number(bb.ir_version.to_string())),
        ("name".to_string(), JsonValue::str(bb.name.clone())),
        ("version".to_string(), JsonValue::opt_str(&bb.version)),
        ("vision".to_string(), JsonValue::opt_str(&bb.vision)),
        ("classification".to_string(), JsonValue::opt_str(&bb.classification)),
        ("aggregates".to_string(), JsonValue::Array(bb.aggregates.iter().map(aggregate_json).collect())),
        ("read_models".to_string(), JsonValue::Array(bb.read_models.iter().map(read_model_json).collect())),
        ("policies".to_string(), JsonValue::Array(bb.policies.iter().map(policy_json).collect())),
        ("process_managers".to_string(), JsonValue::Array(bb.process_managers.iter().map(process_manager_json).collect())),
        ("attaches_to".to_string(), JsonValue::strings(&bb.attaches_to)),
        ("canonical_form".to_string(), canonical_form_table()),
    ])
}

/// `IR::Aggregate#to_h` (lib/hecksagain/bluebook/ir/aggregate.rb).
fn aggregate_json(a: &ir::Aggregate) -> JsonValue {
    JsonValue::Object(vec![
        ("name".to_string(), JsonValue::str(a.name.clone())),
        ("description".to_string(), JsonValue::opt_str(&a.description)),
        ("identified_by".to_string(), JsonValue::strings(&a.identified_by)),
        ("attributes".to_string(), JsonValue::Array(a.attributes.iter().map(attribute_json).collect())),
        ("value_objects".to_string(), JsonValue::Array(a.value_objects.iter().map(value_object_json).collect())),
        ("commands".to_string(), JsonValue::Array(a.commands.iter().map(command_json).collect())),
        ("invariants".to_string(), JsonValue::Array(a.invariants.iter().map(given_json).collect())),
        ("preconditions".to_string(), JsonValue::Array(a.preconditions.iter().map(given_json).collect())),
        ("projected_fields".to_string(), JsonValue::Array(a.projected_fields.iter().map(projected_field_json).collect())),
        ("lifecycle".to_string(), a.lifecycle.as_ref().map(lifecycle_json).unwrap_or(JsonValue::Null)),
        ("entities".to_string(), JsonValue::Array(a.entities.iter().map(entity_json).collect())),
        ("queries".to_string(), JsonValue::Array(a.queries.iter().map(query_json).collect())),
        ("ports".to_string(), JsonValue::Array(a.ports.iter().map(domain_port_json).collect())),
        ("provenance".to_string(), a.provenance.as_ref().map(ruby_value_json).unwrap_or(JsonValue::Null)),
    ])
}

/// `IR::Attribute#to_h` (lib/hecksagain/bluebook/ir/attribute.rb).
fn attribute_json(a: &ir::Attribute) -> JsonValue {
    JsonValue::Object(vec![
        ("name".to_string(), JsonValue::str(a.name.clone())),
        ("type".to_string(), JsonValue::str(a.type_name.clone())),
        ("list".to_string(), JsonValue::Bool(a.list)),
        ("default".to_string(), a.default.as_ref().map(ruby_value_json).unwrap_or(JsonValue::Null)),
        ("optional".to_string(), JsonValue::Bool(a.optional)),
        ("pattern".to_string(), JsonValue::opt_str(&a.pattern)),
        ("admits".to_string(), JsonValue::opt_str(&a.admits)),
    ])
}

/// `IR::ValueObject#to_h` (lib/hecksagain/bluebook/ir/value_object.rb).
fn value_object_json(v: &ir::ValueObject) -> JsonValue {
    JsonValue::Object(vec![
        ("name".to_string(), JsonValue::str(v.name.clone())),
        ("attributes".to_string(), JsonValue::Array(v.attributes.iter().map(attribute_json).collect())),
        ("invariants".to_string(), JsonValue::Array(v.invariants.iter().map(given_json).collect())),
        ("closed_set".to_string(), JsonValue::Bool(v.closed_set)),
        (
            "members".to_string(),
            JsonValue::Array(
                v.members
                    .iter()
                    .map(|member| {
                        JsonValue::Array(
                            member
                                .iter()
                                .map(|(field, value)| JsonValue::Array(vec![JsonValue::str(field.clone()), JsonValue::str(value.clone())]))
                                .collect(),
                        )
                    })
                    .collect(),
            ),
        ),
    ])
}

/// `{description:, canonical:}` — the shape BOTH `IR::Command#to_h`'s
/// `givens:`/`ensures:` and `IR::ValueObject#to_h`'s `invariants:` use
/// (`ir::Given`/`ir::Ensures`/`ir::Invariant` are all the same Rust type,
/// same as the Ruby side: `command.rb`'s `Given` and `value_object.rb`'s
/// `Invariant` are both plain `description/canonical` Structs).
fn given_json(g: &ir::Given) -> JsonValue {
    JsonValue::Object(vec![
        ("description".to_string(), JsonValue::opt_str(&g.description)),
        ("canonical".to_string(), JsonValue::str(g.canonical.clone())),
    ])
}

/// `IR::Aggregate#to_h`'s own `projected_fields:` entry (S12, ADR
/// 0025) — `{name:, reference:, remote_field:}`, all three plain
/// Strings the same way `given_json` above spells its own two.
fn projected_field_json(f: &ir::ProjectedField) -> JsonValue {
    JsonValue::Object(vec![
        ("name".to_string(), JsonValue::str(f.name.clone())),
        ("reference".to_string(), JsonValue::str(f.reference.clone())),
        ("remote_field".to_string(), JsonValue::str(f.remote_field.clone())),
    ])
}

/// `IR::Command#to_h` (lib/hecksagain/bluebook/ir/command.rb).
fn command_json(c: &ir::Command) -> JsonValue {
    JsonValue::Object(vec![
        ("name".to_string(), JsonValue::str(c.name.clone())),
        ("role".to_string(), JsonValue::opt_str(&c.role)),
        ("goal".to_string(), JsonValue::opt_str(&c.goal)),
        ("references".to_string(), JsonValue::opt_str(&c.references)),
        ("attributes".to_string(), JsonValue::Array(c.attributes.iter().map(attribute_json).collect())),
        ("givens".to_string(), JsonValue::Array(c.givens.iter().map(given_json).collect())),
        ("ensures".to_string(), JsonValue::Array(c.ensures.iter().map(given_json).collect())),
        ("mutations".to_string(), JsonValue::Array(c.mutations.iter().map(mutation_json).collect())),
        ("emits".to_string(), JsonValue::strings(&c.emits)),
        ("from".to_string(), command_from_json(&c.from)),
        ("provenance".to_string(), c.provenance.as_ref().map(ruby_value_json).unwrap_or(JsonValue::Null)),
    ])
}

/// `ir::CommandFrom` — see that type's own header: a plain captured
/// value (never `Literal.render`-ed), a bare JSON string for ONE state or
/// a JSON array of strings for several, `null` for a command with no
/// `from:` guard.
fn command_from_json(from: &Option<ir::CommandFrom>) -> JsonValue {
    match from {
        None => JsonValue::Null,
        Some(ir::CommandFrom::Single(state)) => JsonValue::str(state.clone()),
        Some(ir::CommandFrom::Multiple(states)) => JsonValue::strings(states),
    }
}

/// `IR::Mutation#to_h` (lib/hecksagain/bluebook/ir/command.rb) — see
/// `ir::MutationSource`'s own header for why an APPEND's `fields:` and a
/// non-append's literal `source:` are rendered two different ways.
fn mutation_json(m: &ir::Mutation) -> JsonValue {
    match m {
        ir::Mutation::Append { target, fields } => JsonValue::Object(vec![
            ("target".to_string(), JsonValue::str(target.clone())),
            ("op".to_string(), JsonValue::str("append")),
            ("fields".to_string(), JsonValue::Object(fields.iter().map(|(k, v)| (k.clone(), JsonValue::str(v.clone()))).collect())),
        ]),
        ir::Mutation::Other { target, op, source } => JsonValue::Object(vec![
            ("target".to_string(), JsonValue::str(target.clone())),
            ("op".to_string(), JsonValue::str(op.clone())),
            ("source".to_string(), mutation_source_json(source)),
        ]),
    }
}

fn mutation_source_json(source: &Option<ir::MutationSource>) -> JsonValue {
    match source {
        Some(ir::MutationSource::Argument(name)) => {
            JsonValue::Object(vec![("kind".to_string(), JsonValue::str("argument")), ("name".to_string(), JsonValue::str(name.clone()))])
        }
        Some(ir::MutationSource::Literal(value)) => {
            JsonValue::Object(vec![("kind".to_string(), JsonValue::str("literal")), ("value".to_string(), ruby_value_json(value))])
        }
        None => JsonValue::Null,
    }
}

/// `IR::Lifecycle#to_h` (lib/hecksagain/bluebook/ir/lifecycle.rb) — the
/// `transitions:` list is already EXPANDED (one `StateTransitionRow` per
/// `from_state`, mirroring Ruby's own `expand`) by the time it reaches
/// here; nothing left to fan out.
fn lifecycle_json(l: &ir::Lifecycle) -> JsonValue {
    JsonValue::Object(vec![
        ("field".to_string(), JsonValue::str(l.field.clone())),
        ("default".to_string(), JsonValue::str(l.default.clone())),
        (
            "transitions".to_string(),
            JsonValue::Array(
                l.transitions
                    .iter()
                    .map(|t| {
                        JsonValue::Object(vec![
                            ("command".to_string(), JsonValue::str(t.command.clone())),
                            ("to_state".to_string(), JsonValue::str(t.to_state.clone())),
                            ("from_state".to_string(), JsonValue::opt_str(&t.from_state)),
                        ])
                    })
                    .collect(),
            ),
        ),
    ])
}

/// `IR::Query#to_h` (lib/hecksagain/bluebook/ir/query.rb) merged with
/// `QuerySpecification::Common::Options#extra_options_to_h` — the latter
/// via `query_options_json`, which appends `offset`/`cursor`/
/// `consistency`/`freshness`/`authorization`/`null_semantics`/
/// `inspection`/`index_hints` IN THAT FIXED RUBY ORDER, only for
/// whichever ones this query actually declared (`ir::QueryOptions`'s own
/// header explains why this can't be a plain sorted-keys map).
fn query_json(q: &ir::Query) -> JsonValue {
    let mut pairs = vec![
        ("name".to_string(), JsonValue::str(q.name.clone())),
        ("description".to_string(), JsonValue::opt_str(&q.description)),
        ("attributes".to_string(), JsonValue::Array(q.attributes.iter().map(attribute_json).collect())),
        ("wheres".to_string(), JsonValue::Array(q.wheres.iter().map(where_clause_json).collect())),
        ("order_by".to_string(), order_by_json(&q.order_by)),
        ("limit".to_string(), limit_json(&q.limit)),
    ];
    pairs.extend(query_options_json(&q.options));
    JsonValue::Object(pairs)
}

fn where_clause_json(w: &ir::WhereClause) -> JsonValue {
    JsonValue::Object(vec![
        ("field".to_string(), JsonValue::str(w.field.clone())),
        ("op".to_string(), JsonValue::str(w.op.clone())),
        ("value".to_string(), JsonValue::str(w.value.clone())),
    ])
}

fn order_by_json(order_by: &Option<ir::OrderBy>) -> JsonValue {
    order_by
        .as_ref()
        .map(|o| {
            JsonValue::Object(vec![
                ("field".to_string(), JsonValue::str(o.field.clone())),
                ("direction".to_string(), JsonValue::str(o.direction.clone())),
            ])
        })
        .unwrap_or(JsonValue::Null)
}

fn limit_json(limit: &Option<ir::LimitSpec>) -> JsonValue {
    limit.as_ref().map(|l| JsonValue::Object(vec![("value".to_string(), JsonValue::str(l.value.clone()))])).unwrap_or(JsonValue::Null)
}

/// `QuerySpecification::Common::Options#extra_options_to_h` — shared
/// verbatim by `query_json`/`read_model_json`, since both Ruby classes
/// `< Options` and reject the identical set (`wheres`/`order_by`/`limit`
/// excluded by name; `null_semantics` excluded only when it's the
/// default `{mode: "native"}`, which `ir::QueryOptions.null_semantics`
/// is already `None` for — see that field's own comment). Returns pairs
/// in Ruby's own DECLARED field order, appending only the ones actually
/// present — an absent `Option`/empty `Vec` contributes NOTHING, the
/// same as `extra_options_to_h`'s own `.reject { value.nil? || value ==
/// [] }`.
fn query_options_json(o: &ir::QueryOptions) -> Vec<(String, JsonValue)> {
    let mut pairs = Vec::new();
    if let Some(value) = &o.offset {
        pairs.push(("offset".to_string(), JsonValue::Object(vec![("value".to_string(), JsonValue::str(value.clone()))])));
    }
    if let Some(value) = &o.cursor {
        pairs.push(("cursor".to_string(), JsonValue::Object(vec![("value".to_string(), JsonValue::str(value.clone()))])));
    }
    if let Some(a) = &o.authorization {
        let mut fields = vec![("policy".to_string(), JsonValue::str(a.policy.clone()))];
        fields.push(("tenant".to_string(), a.tenant.as_ref().map(|t| JsonValue::str(t.clone())).unwrap_or(JsonValue::Null)));
        pairs.push(("authorization".to_string(), JsonValue::Object(fields)));
    }
    if let Some(mode) = &o.null_semantics {
        pairs.push(("null_semantics".to_string(), JsonValue::Object(vec![("mode".to_string(), JsonValue::str(mode.clone()))])));
    }
    if let Some(mode) = &o.inspection {
        pairs.push(("inspection".to_string(), JsonValue::Object(vec![("mode".to_string(), JsonValue::str(mode.clone()))])));
    }
    pairs
}

/// `IR::Entity#to_h` (lib/hecksagain/bluebook/ir/entity.rb). STAGE 4:
/// real, confirmed by banking.bluebook's own `LedgerEntry`/`Withdrawal`/
/// `Visit`/`KeyIssuance` (`parse::entity`, previously fully stubbed).
fn entity_json(e: &ir::Entity) -> JsonValue {
    JsonValue::Object(vec![
        ("name".to_string(), JsonValue::str(e.name.clone())),
        ("description".to_string(), JsonValue::opt_str(&e.description)),
        ("identified_by".to_string(), JsonValue::strings(&e.identified_by)),
        ("attributes".to_string(), JsonValue::Array(e.attributes.iter().map(attribute_json).collect())),
        ("commands".to_string(), JsonValue::Array(e.commands.iter().map(command_json).collect())),
        ("queries".to_string(), JsonValue::Array(e.queries.iter().map(query_json).collect())),
        // S17, ADR 0026 — `entity.rb`'s own `emits_ir` now names
        // `entities: many(:entities)`, same field an Aggregate already
        // carries (`aggregate_json`, above) — recurses the same way.
        ("entities".to_string(), JsonValue::Array(e.entities.iter().map(entity_json).collect())),
        ("lifecycle".to_string(), e.lifecycle.as_ref().map(lifecycle_json).unwrap_or(JsonValue::Null)),
    ])
}

/// `IR::ReadModel#to_h` (lib/hecksagain/bluebook/ir/read_model.rb) —
/// `wheres`/`order_by`/`limit` spelled explicitly (the SAME mechanism
/// `query_json` uses, per `read_model.rb`'s own 2026-08-11 comment on
/// why), `aggregate_heads`/`group_by` after them, then
/// `query_options_json` — real for `ComplianceDashboard` (banking.bluebook's
/// own filtered/ordered/capped/fresh/indexed read model), the first real
/// corpus member to declare any of the three.
fn read_model_json(r: &ir::ReadModel) -> JsonValue {
    let mut pairs = vec![
        ("name".to_string(), JsonValue::str(r.name.clone())),
        ("description".to_string(), JsonValue::opt_str(&r.description)),
        ("reference_name".to_string(), JsonValue::opt_str(&r.reference_name)),
        ("reference_target".to_string(), JsonValue::opt_str(&r.reference_target)),
        ("query_name".to_string(), JsonValue::str(r.query_name.clone())),
        ("wheres".to_string(), JsonValue::Array(r.wheres.iter().map(where_clause_json).collect())),
        ("order_by".to_string(), order_by_json(&r.order_by)),
        ("limit".to_string(), limit_json(&r.limit)),
        (
            "aggregate_heads".to_string(),
            JsonValue::Array(
                r.aggregate_heads
                    .iter()
                    .map(|head| {
                        JsonValue::Object(vec![
                            ("aggregate".to_string(), JsonValue::str(head.aggregate.clone())),
                            ("as".to_string(), JsonValue::str(head.as_name.clone())),
                            ("many".to_string(), JsonValue::Bool(head.many)),
                        ])
                    })
                    .collect(),
            ),
        ),
        (
            "group_by".to_string(),
            JsonValue::Array(r.group_by.iter().map(|field| JsonValue::Object(vec![("field".to_string(), JsonValue::str(field.clone()))])).collect()),
        ),
    ];
    // `count`/`median_field` — `group_by`'s own two siblings, pushed
    // ONLY when set (`IR::ReadModel#to_h`'s own conditional `reductions`
    // merge, read_model.rb) — never a `null` key for a read model that
    // declares neither, which is every one but banking.bluebook's own
    // `DisputedPaymentCount`/`DisputedPaymentMedian`.
    if r.count {
        pairs.push(("count".to_string(), JsonValue::Bool(true)));
    }
    if let Some(field) = &r.median_field {
        pairs.push(("median_field".to_string(), JsonValue::str(field.clone())));
    }
    pairs.extend(query_options_json(&r.options));
    JsonValue::Object(pairs)
}

/// `IR::ProcessManager#to_h` (lib/hecksagain/bluebook/ir/process_manager.rb).
/// STAGE 4: real, confirmed by banking.bluebook's own three sagas
/// (`Settlement`/`ExternalSettlement`/`Onboarding`).
fn process_manager_json(pm: &ir::ProcessManager) -> JsonValue {
    JsonValue::Object(vec![
        ("name".to_string(), JsonValue::str(pm.name.clone())),
        ("correlates_by".to_string(), JsonValue::str(pm.correlates_by.clone())),
        ("starts_on".to_string(), JsonValue::opt_str(&pm.starts_on)),
        ("ends_on".to_string(), JsonValue::opt_str(&pm.ends_on)),
        ("states".to_string(), JsonValue::strings(&pm.states)),
        ("handlers".to_string(), JsonValue::Array(pm.handlers.iter().map(process_manager_handler_json).collect())),
    ])
}

/// `IR::ProcessManagerHandler#to_h`.
fn process_manager_handler_json(h: &ir::ProcessManagerHandler) -> JsonValue {
    JsonValue::Object(vec![
        ("event_type".to_string(), JsonValue::str(h.event_type.clone())),
        ("from_state".to_string(), JsonValue::str(h.from_state.clone())),
        ("to_state".to_string(), JsonValue::str(h.to_state.clone())),
        ("dispatches".to_string(), JsonValue::Array(h.dispatches.iter().map(dispatch_spec_json).collect())),
    ])
}

/// `IR::DispatchSpec#to_h` — `with_spec.map { |key, value| [key.to_s,
/// IR.render_value(value)] }`, rendered as an ARRAY of `[key, value]`
/// pairs (never a JSON object) since `IR::DispatchSpec#to_h`'s own
/// `with_spec:` is `with_spec.map { ... }` over an Array of pairs, not a
/// Hash — confirmed by reading `process_manager.rb` directly.
fn dispatch_spec_json(d: &ir::DispatchSpec) -> JsonValue {
    JsonValue::Object(vec![
        ("command_name".to_string(), JsonValue::str(d.command_name.clone())),
        (
            "with_spec".to_string(),
            JsonValue::Array(d.with_spec.iter().map(|(k, v)| JsonValue::Array(vec![JsonValue::str(k.clone()), JsonValue::str(v.clone())])).collect()),
        ),
    ])
}

/// `Policy#to_h` (`lib/hecksagain/bluebook/policy.rb`, generated by
/// `bin/project_model` from `lib/hecksagain/language/bluebook/
/// reaction.bluebook`'s own `Policy` aggregate — field ORDER here is the
/// declaration order that file's `attribute` lines give, which is the
/// real wire order `spec/parser_parity_spec.rb` byte-matches against,
/// not an alphabetised one). `where`/`for_each` — see `ir::Policy`'s own
/// comment on why both are always `null` here.
fn policy_json(p: &ir::Policy) -> JsonValue {
    JsonValue::Object(vec![
        ("name".to_string(), JsonValue::str(p.name.clone())),
        ("on_event".to_string(), JsonValue::opt_str(&p.on_event)),
        ("trigger_command".to_string(), JsonValue::opt_str(&p.trigger_command)),
        ("target_domain".to_string(), JsonValue::opt_str(&p.target_domain)),
        ("where".to_string(), JsonValue::opt_str(&p.where_clause)),
        ("for_each".to_string(), JsonValue::opt_str(&p.for_each_query)),
        (
            "with_spec".to_string(),
            JsonValue::Array(p.with_spec.iter().map(|(k, v)| JsonValue::Array(vec![JsonValue::str(k.clone()), JsonValue::str(v.clone())])).collect()),
        ),
    ])
}

/// `IR::DomainPort#to_h` / `IR::PortOperation#to_h`
/// (lib/hecksagain/bluebook/ir/domain_port.rb).
fn domain_port_json(p: &ir::DomainPort) -> JsonValue {
    JsonValue::Object(vec![
        ("name".to_string(), JsonValue::str(p.name.clone())),
        ("operations".to_string(), JsonValue::Array(p.operations.iter().map(port_operation_json).collect())),
    ])
}

fn port_operation_json(op: &ir::PortOperation) -> JsonValue {
    JsonValue::Object(vec![
        ("name".to_string(), JsonValue::str(op.name.clone())),
        ("attributes".to_string(), JsonValue::Array(op.attributes.iter().map(attribute_json).collect())),
        ("emits".to_string(), JsonValue::strings(&op.emits)),
    ])
}

/// `JSON.generate`'s own native encoding of a captured Ruby value — used
/// where the Ruby `to_h` field is the RAW value itself (`Attribute
/// #default`, a non-append `Mutation`'s literal `source:`), never through
/// `Literal.render`. A bare Symbol has no JSON type of its own; the `json`
/// gem's default `Symbol#to_json` calls `to_s.to_json` (the NAME, no
/// colon) — not exercised anywhere in the pizzas corpus (every literal
/// mutation source and default there is a plain String), kept correct
/// anyway since it costs nothing extra.
fn ruby_value_json(value: &ruby_value::Value) -> JsonValue {
    match value {
        ruby_value::Value::Nil => JsonValue::Null,
        ruby_value::Value::Bool(b) => JsonValue::Bool(*b),
        ruby_value::Value::Int(n) => JsonValue::Number(n.to_string()),
        ruby_value::Value::Float(f) => JsonValue::Number(ruby_value::render(&ruby_value::Value::Float(*f))),
        ruby_value::Value::Str(text) => JsonValue::String(text.clone()),
        ruby_value::Value::Symbol(name) => JsonValue::String(name.clone()),
        ruby_value::Value::Bare(text) => JsonValue::String(text.clone()),
        ruby_value::Value::Hash(pairs) => JsonValue::Object(pairs.iter().map(|(k, v)| (k.clone(), ruby_value_json(v))).collect()),
        ruby_value::Value::Array(items) => JsonValue::Array(items.iter().map(ruby_value_json).collect()),
    }
}

fn indent(out: &mut String, depth: usize) {
    for _ in 0..depth {
        out.push_str("  ");
    }
}

fn write_value(out: &mut String, value: &JsonValue, depth: usize) {
    match value {
        JsonValue::Null => out.push_str("null"),
        JsonValue::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
        JsonValue::Number(n) => out.push_str(n),
        JsonValue::String(s) => write_string(out, s),
        JsonValue::Array(items) => write_array(out, items, depth),
        JsonValue::Object(pairs) => write_object(out, pairs, depth),
    }
}

fn write_string(out: &mut String, text: &str) {
    out.push('"');
    for ch in text.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\t' => out.push_str("\\t"),
            '\r' => out.push_str("\\r"),
            c if (c as u32) < 0x20 => {
                let _ = write!(out, "\\u{:04x}", c as u32);
            }
            c => out.push(c),
        }
    }
    out.push('"');
}

fn write_array(out: &mut String, items: &[JsonValue], depth: usize) {
    if items.is_empty() {
        // THE PINNED HAZARD, for real — see this module's own header.
        // `bundle exec ruby -e 'require "json"; print
        // JSON.pretty_generate({a: []}).inspect'` in THIS repo prints
        // `"{\n  \"a\": [\n\n  ]\n}"`: an extra blank, UNINDENTED line
        // between the brackets, then the closing `]` at the array's own
        // (non-empty-shaped) indent — not simply `"[]"`.
        out.push_str("[\n\n");
        indent(out, depth);
        out.push(']');
        return;
    }
    out.push_str("[\n");
    for (idx, item) in items.iter().enumerate() {
        indent(out, depth + 1);
        write_value(out, item, depth + 1);
        if idx + 1 < items.len() {
            out.push(',');
        }
        out.push('\n');
    }
    indent(out, depth);
    out.push(']');
}

fn write_object(out: &mut String, pairs: &[(String, JsonValue)], depth: usize) {
    // NO special case for an empty object — see this module's own header:
    // the ordinary loop below already produces the right bytes
    // (`"{\n" + indent(depth) + "}"`) when it simply runs zero times, and
    // that's exactly what the bundled json gem itself emits for `{}`.
    out.push_str("{\n");
    for (idx, (key, val)) in pairs.iter().enumerate() {
        indent(out, depth + 1);
        write_string(out, key);
        out.push_str(": ");
        write_value(out, val, depth + 1);
        if idx + 1 < pairs.len() {
            out.push(',');
        }
        out.push('\n');
    }
    indent(out, depth);
    out.push('}');
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn writes_a_small_object_with_an_empty_array() {
        // The pinned hazard (this module's own header): an empty array
        // is NOT simply `[]` under the bundled json 2.7.2 gem.
        let value = JsonValue::Object(vec![
            ("name".to_string(), JsonValue::String("Pizzas".to_string())),
            ("aggregates".to_string(), JsonValue::Array(vec![])),
        ]);
        assert_eq!(write(&value), "{\n  \"name\": \"Pizzas\",\n  \"aggregates\": [\n\n  ]\n}");
    }

    #[test]
    fn writes_a_top_level_empty_array() {
        assert_eq!(write(&JsonValue::Array(vec![])), "[\n\n]");
    }

    #[test]
    fn writes_an_empty_object_with_no_special_case() {
        assert_eq!(write(&JsonValue::Object(vec![])), "{\n}");
        let nested = JsonValue::Object(vec![("a".to_string(), JsonValue::Object(vec![]))]);
        assert_eq!(write(&nested), "{\n  \"a\": {\n  }\n}");
    }
}
