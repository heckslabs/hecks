//! Port of the retired Ruby generator's `mutations.rb`, function for function.
//! `mark_append_optional_fields!` is not ported: `Json` has no mutation API and the corpus
//! already declares `optional: true` on every field that pass would touch.

use crate::exemplar::Exemplar;
use crate::json::Json;
use crate::literal::{self, Literal};
use crate::naming;
use std::collections::HashMap;

/// Resolves `append`'s target to a local entity or a domain-wide value object.
///
/// Local entities are checked first: value objects are merged domain-wide, so a same-named
/// value object (Command's `Argument`) must not shadow Syntax's own `Argument` entity.
pub fn append_element<'a>(aggregate: &'a Json, target_type: &str, value_objects_by_name: &HashMap<String, &'a Json>) -> Option<&'a Json> {
    if let Some(local) = aggregate.get("entities").map(Json::each).unwrap_or(&[]).iter().find(|e| e.get("name").and_then(Json::as_str) == Some(target_type)) {
        return Some(local);
    }
    value_objects_by_name.get(target_type).copied()
}

/// Returns an entity's identity attribute and its single-field value object, when it can be
/// auto-minted at append time.
pub fn entity_identity_mint<'a>(entity: &'a Json, value_objects_by_name: &HashMap<String, &'a Json>) -> Option<(&'a Json, &'a Json)> {
    let identified_by = entity.get("identified_by").map(Json::each).unwrap_or(&[]);
    let id_path = identified_by.first()?.as_str()?;
    let mut parts = id_path.split('.');
    let head = parts.next()?;
    let rest: Vec<&str> = parts.collect();
    if rest.len() != 1 {
        return None;
    }

    let attrs = entity.get("attributes").map(Json::each).unwrap_or(&[]);
    let attr = attrs.iter().find(|a| crate::attr::name(a) == head)?;
    let vo = value_objects_by_name.get(crate::attr::type_name(attr)).copied()?;
    if vo.get("closed_set").map(Json::as_bool).unwrap_or(false) {
        return None;
    }
    let vo_attrs = vo.get("attributes").map(Json::each).unwrap_or(&[]);
    if vo_attrs.len() != 1 || crate::attr::name(&vo_attrs[0]) != rest[0] {
        return None;
    }
    Some((attr, vo))
}

/// Returns the duplicate-identity guard for a whole-list `set`, and the right-hand side to assign.
///
/// A missing identity needs no guard: the generated `Entity::from_json` already refuses it.
/// Every `identified_by` head is compared at once (not just the first), so a composite identity
/// is guarded the same as a single-field one — see `check_entity_collision` in
/// `entity_element.rb` (Ruby's `heads.all?`).
pub fn entity_list_replace_guard<'a>(aggregate: &Json, target_attr: &Json, target_field: &str, rhs: &str, value_objects_by_name: &HashMap<String, &'a Json>) -> (String, String) {
    let target_type = crate::attr::type_name(target_attr);
    let entity = aggregate.get("entities").map(Json::each).unwrap_or(&[]).iter().find(|e| e.get("name").and_then(Json::as_str) == Some(target_type));
    let entity = match entity {
        Some(e) => e,
        None => return (String::new(), rhs.to_string()),
    };
    let identified_by = entity.get("identified_by").map(Json::each).unwrap_or(&[]);
    if identified_by.is_empty() {
        return (String::new(), rhs.to_string());
    }

    let attrs = entity.get("attributes").map(Json::each).unwrap_or(&[]);
    let mut checks = Vec::new();
    let mut offered_exprs = Vec::new();
    for path in identified_by {
        let id_head = path.to_s().split('.').next().unwrap_or_default().to_string();
        let id_attr = match attrs.iter().find(|a| crate::attr::name(a) == id_head) {
            Some(a) => a,
            None => return (String::new(), rhs.to_string()),
        };
        let id_field = naming::rust_ident_field(crate::attr::name(id_attr));
        checks.push(format!("prior.{id_field} == e.{id_field}"));

        // Unwrap a single-field identity so `offered` prints the bare scalar, as
        // `Rendering.describe` does; Debug-printing the value object would give
        // `EntrySequence { value: 1 }`.
        let id_vo = value_objects_by_name.get(crate::attr::type_name(id_attr)).copied();
        let offered_expr = match id_vo {
            Some(vo) if !vo.get("closed_set").map(Json::as_bool).unwrap_or(false) && vo.get("attributes").map(Json::each).unwrap_or(&[]).len() == 1 => {
                let inner = naming::rust_ident_field(crate::attr::name(&vo.get("attributes").map(Json::each).unwrap_or(&[])[0]));
                format!("e.{id_field}.{inner}")
            }
            _ => format!("e.{id_field}"),
        };
        offered_exprs.push(offered_expr);
    }

    let local_var = format!("replaced_{target_field}");
    let entity_name = entity.get("name").and_then(Json::as_str).unwrap_or_default();
    let aggregate_name = aggregate.get("name").and_then(Json::as_str).unwrap_or_default();
    let identity_reading = identified_by.iter().map(Json::to_s).collect::<Vec<_>>().join(", ");
    let entity_lit = naming::ruby_inspect_string(entity_name);
    let aggregate_lit = naming::ruby_inspect_string(aggregate_name);
    let identity_lit = naming::ruby_inspect_string(&identity_reading);
    let condition = checks.join(" && ");
    let offered_lets: Vec<String> = offered_exprs.iter().enumerate().map(|(i, expr)| format!("let offered_{i} = format!(\"{{:?}}\", {expr});")).collect();
    let offered_refs: Vec<String> = (0..offered_exprs.len()).map(|i| format!("offered_{i}.as_str()")).collect();
    let guard = format!(
        "let {local_var} = {rhs};\n        for (i, e) in {local_var}.iter().enumerate() {{ if {local_var}[..i].iter().any(|prior| {condition}) {{ {} let offered = [{}]; return Err(crate::kernel::Refusal::AlreadyExists(crate::kernel::refusal_wording::AlreadyExistsEntityDuplicateArgs {{ entity: {entity_lit}, aggregate: {aggregate_lit}, identity: {identity_lit}, offered: &offered }}.render_args())); }} }}\n        ",
        offered_lets.join(" "), offered_refs.join(", ")
    );
    (guard, local_var)
}

/// The composite-identity twin of the single-field collision guard inlined in
/// `emit_mutation_line_body`'s `append` branch: builds a duplicate check across every
/// `identified_by` head at once (`e.batch == ... && e.sequence == ...`), matching
/// `EntityElement.check_entity_collision`'s `heads.all?` on the Ruby side. Called only once every
/// head is confirmed present in the append's own `fields` map (composite identities never mint).
#[allow(clippy::too_many_arguments)]
fn composite_append_collision_guard(
    heads: &[String],
    fields: &[(String, String)],
    element_attrs: &[Json],
    command: &Json,
    value_objects_by_name: &HashMap<String, &Json>,
    target_field: &str,
    entity: &Json,
    aggregate: &Json,
    identified_by: &[Json],
) -> String {
    let mut checks = Vec::new();
    let mut offered_exprs = Vec::new();
    for head in heads {
        let field_attr = element_attrs
            .iter()
            .find(|a| crate::attr::name(a) == head.as_str())
            .expect("composite identity head must be a declared element attribute");
        let (_, source) = fields
            .iter()
            .find(|(k, _)| k == head)
            .expect("composite identity head must be in the append's own field map");
        let rhs = append_field_rhs(source, field_attr, command, value_objects_by_name);
        let id_field = naming::rust_ident_field(head);
        checks.push(format!("e.{id_field} == {rhs}"));

        // Unwrap a single-field identity component so `offered` prints the bare scalar, as
        // `Rendering.describe` does; Debug-printing the value object would give
        // `LineSequence { value: 654 }`.
        let vo = value_objects_by_name.get(crate::attr::type_name(field_attr)).copied();
        let offered_expr = match vo {
            Some(vo) if !vo.get("closed_set").map(Json::as_bool).unwrap_or(false) && vo.get("attributes").map(Json::each).unwrap_or(&[]).len() == 1 => {
                let inner = naming::rust_ident_field(crate::attr::name(&vo.get("attributes").map(Json::each).unwrap_or(&[])[0]));
                format!("{rhs}.{inner}")
            }
            _ => rhs,
        };
        offered_exprs.push(offered_expr);
    }

    let entity_name = entity.get("name").and_then(Json::as_str).unwrap_or_default();
    let aggregate_name = aggregate.get("name").and_then(Json::as_str).unwrap_or_default();
    let identity_reading = identified_by.iter().map(Json::to_s).collect::<Vec<_>>().join(", ");
    let entity_lit = naming::ruby_inspect_string(entity_name);
    let aggregate_lit = naming::ruby_inspect_string(aggregate_name);
    let identity_lit = naming::ruby_inspect_string(&identity_reading);
    let condition = checks.join(" && ");
    let offered_lets: Vec<String> = offered_exprs
        .iter()
        .enumerate()
        .map(|(i, expr)| format!("let offered_{i} = format!(\"{{:?}}\", {expr});"))
        .collect();
    let offered_refs: Vec<String> = (0..offered_exprs.len()).map(|i| format!("offered_{i}.as_str()")).collect();

    format!(
        "if record.{target_field}.iter().any(|e| {condition}) {{ {} let offered = [{}]; return Err(crate::kernel::Refusal::AlreadyExists(crate::kernel::refusal_wording::AlreadyExistsEntityDuplicateArgs {{ entity: {entity_lit}, aggregate: {aggregate_lit}, identity: {identity_lit}, offered: &offered }}.render_args())); }}\n        ",
        offered_lets.join(" "), offered_refs.join(", ")
    )
}

/// Inverse of `appended_fields`' spelling: a leading `:` is a command argument, else a literal.
pub fn append_field_source(source: &str) -> Literal {
    literal::read(source)
}

/// Whether any effect reads the record's own state, so the closure must bind `let pre`.
pub fn reads_pre_state(mutations: &[Json]) -> bool {
    mutations.iter().any(|m| match m.get("op").map(Json::to_s).unwrap_or_default().as_str() {
        "set" => m.get("source").and_then(|s| s.get("kind")).map(Json::to_s).unwrap_or_default() == "state",
        "append" => match m.get("fields") {
            Some(Json::Object(pairs)) => pairs.iter().any(|(_, source)| source.to_s().starts_with("state(:")),
            _ => false,
        },
        _ => false,
    })
}

pub fn pre_state_line() -> String {
    "        let pre = record.clone();".to_string()
}

// Integer arithmetic that leaves signed 64 bits is a `Refusal::Fault`, never a wrap or a panic.
fn checked_arithmetic(op: &str, field_ident: &str, symbol: &str, amount_expr: &str) -> String {
    let checked = match symbol {
        "+" => "checked_add",
        "-" => "checked_sub",
        "*" => "checked_mul",
        other => panic!("no checked arithmetic for {other:?}"),
    };
    format!(
        "{{ let amount = {amount_expr}; current.{field_ident}.{checked}(amount).ok_or_else(|| crate::kernel::Refusal::Fault(format!(\"{op} overflowed: {{}} {symbol} {{}} does not fit in a 64-bit integer\", current.{field_ident}, amount)))? }}"
    )
}

pub fn literal_problem(mutation: &Json, field_name: &str, lit: &Literal, field_attr: &Json, value_objects_by_name: &HashMap<String, &Json>) -> Option<String> {
    if crate::bridging::literal_set_bridgeable(lit, Some(crate::attr::type_name(field_attr)), value_objects_by_name) {
        return None;
    }
    let target = mutation.get("target").map(Json::to_s).unwrap_or_default();
    Some(format!("{target}.{field_name}: literal doesn't bridge to {}", crate::attr::type_name(field_attr)))
}

/// Problems with `set`/`append` fields sourced from `state(:field)`: an undeclared state field,
/// or a type or cardinality that differs from the target's.
pub fn state_source_problems(command: &Json, aggregate: &Json, value_objects_by_name: &HashMap<String, &Json>) -> Vec<String> {
    let attrs = aggregate.get("attributes").map(Json::each).unwrap_or(&[]);
    let mutations = command.get("mutations").map(Json::each).unwrap_or(&[]);
    mutations
        .iter()
        .flat_map(|m| {
            let target = m.get("target").map(Json::to_s).unwrap_or_default();
            match m.get("op").map(Json::to_s).unwrap_or_default().as_str() {
                "set" => {
                    let source = m.get("source");
                    if source.and_then(|s| s.get("kind")).map(Json::to_s).unwrap_or_default() != "state" {
                        return Vec::new();
                    }
                    let state_name = source.and_then(|s| s.get("name")).map(Json::to_s).unwrap_or_default();
                    state_source_problem(&target, &state_name, aggregate, attrs.iter().find(|a| crate::attr::name(a) == target)).into_iter().collect()
                }
                "append" => {
                    let Some(target_attr) = attrs.iter().find(|a| crate::attr::name(a) == target) else { return Vec::new() };
                    let Some(element) = append_element(aggregate, crate::attr::type_name(target_attr), value_objects_by_name) else { return Vec::new() };
                    let element_attrs = element.get("attributes").map(Json::each).unwrap_or(&[]);
                    let Some(Json::Object(fields)) = m.get("fields") else { return Vec::new() };
                    fields
                        .iter()
                        .filter_map(|(field_name, source)| {
                            let text = source.to_s();
                            let state_name = text.strip_prefix("state(:")?.strip_suffix(')')?;
                            state_source_problem(&format!("{target}.{field_name}"), state_name, aggregate, element_attrs.iter().find(|a| crate::attr::name(a) == field_name))
                        })
                        .collect()
                }
                _ => Vec::new(),
            }
        })
        .collect()
}

fn state_source_problem(label: &str, state_name: &str, aggregate: &Json, target_attr: Option<&Json>) -> Option<String> {
    let attrs = aggregate.get("attributes").map(Json::each).unwrap_or(&[]);
    let Some(state_attr) = attrs.iter().find(|a| crate::attr::name(a) == state_name) else {
        let aggregate_name = aggregate.get("name").map(Json::to_s).unwrap_or_default();
        return Some(format!("{label}: sources state(:{state_name}), which {aggregate_name} does not declare"));
    };
    let Some(target_attr) = target_attr else {
        return Some(format!("{label}: no such target field"));
    };
    let same = crate::attr::type_name(state_attr) == crate::attr::type_name(target_attr) && crate::attr::list(state_attr) == crate::attr::list(target_attr);
    if same {
        return None;
    }
    let list_of = |a: &Json| if crate::attr::list(a) { "a list of " } else { "" };
    Some(format!(
        "{label}: state(:{state_name}) is {}{}, the target wants {}{} — not generated yet",
        list_of(state_attr),
        crate::attr::type_name(state_attr),
        list_of(target_attr),
        crate::attr::type_name(target_attr)
    ))
}

/// Problems with each `append` mutation's fields, checked against the element they build.
pub fn append_field_problems(command: &Json, aggregate: &Json, value_objects_by_name: &HashMap<String, &Json>) -> Vec<String> {
    let mutations = command.get("mutations").map(Json::each).unwrap_or(&[]);
    mutations
        .iter()
        .filter(|m| m.get("op").map(Json::to_s).unwrap_or_default() == "append")
        .flat_map(|m| {
            let target_name = m.get("target").map(Json::to_s).unwrap_or_default();
            let attrs = aggregate.get("attributes").map(Json::each).unwrap_or(&[]);
            let target_attr = attrs.iter().find(|a| crate::attr::name(a) == target_name);
            let element = target_attr.and_then(|ta| append_element(aggregate, crate::attr::type_name(ta), value_objects_by_name));
            let Some(element) = element else {
                let type_desc = target_attr.map(crate::attr::type_name).unwrap_or("");
                return vec![format!("{target_name}: element type {} not resolvable", naming::ruby_inspect_string(type_desc))];
            };
            let target_attr = target_attr.unwrap();

            let fields = m.get("fields").map(fields_pairs).unwrap_or_default();
            let element_attrs = element.get("attributes").map(Json::each).unwrap_or(&[]);
            let mut problems: Vec<String> = fields
                .iter()
                .filter_map(|(field_name, source)| {
                    let field_attr = element_attrs.iter().find(|a| crate::attr::name(a) == field_name.as_str());
                    let Some(field_attr) = field_attr else {
                        return Some(format!("{target_name}.{field_name}: not a declared field"));
                    };

                    let parsed = append_field_source(source);
                    let Literal::Symbol(arg_name) = &parsed else {
                        return literal_problem(m, field_name, &parsed, field_attr, value_objects_by_name);
                    };

                    let cmd_attrs = command.get("attributes").map(Json::each).unwrap_or(&[]);
                    match cmd_attrs.iter().find(|a| crate::attr::name(a) == arg_name.as_str()) {
                        None => Some(format!("{target_name}.{field_name}: sources undeclared argument {arg_name}")),
                        Some(arg_attr) if !crate::bridging::bridgeable_value_types(crate::attr::type_name(arg_attr), crate::attr::type_name(field_attr), value_objects_by_name) => {
                            Some(format!("{target_name}.{field_name}: {} doesn't bridge to {}", crate::attr::type_name(arg_attr), crate::attr::type_name(field_attr)))
                        }
                        _ => None,
                    }
                })
                .collect();

            let entity = aggregate.get("entities").map(Json::each).unwrap_or(&[]).iter().find(|e| e.get("name").and_then(Json::as_str) == Some(crate::attr::type_name(target_attr)));
            if let Some(entity) = entity {
                let present: Vec<String> = fields.iter().map(|(k, _)| k.clone()).collect();
                let identified_by = entity.get("identified_by").map(Json::each).unwrap_or(&[]);
                let id_head = identified_by.first().and_then(Json::as_str).unwrap_or("").split('.').next().unwrap_or("").to_string();
                if !present.contains(&id_head) && entity_identity_mint(entity, value_objects_by_name).is_none() {
                    problems.push(format!("{target_name}: {}'s identity doesn't auto-mint", entity.get("name").and_then(Json::as_str).unwrap_or("")));
                }
            }
            problems
        })
        .collect()
}

/// Problems with `remove:` mutations, which are generatable only against an entity list whose
/// single-head identity mints, sourced from a declared argument that bridges to its type.
pub fn remove_field_problems(command: &Json, aggregate: &Json, value_objects_by_name: &HashMap<String, &Json>) -> Vec<String> {
    let mutations = command.get("mutations").map(Json::each).unwrap_or(&[]);
    mutations
        .iter()
        .filter(|m| m.get("op").map(Json::to_s).unwrap_or_default() == "remove")
        .filter_map(|m| {
            let target_name = m.get("target").map(Json::to_s).unwrap_or_default();
            let attrs = aggregate.get("attributes").map(Json::each).unwrap_or(&[]);
            let Some(target_attr) = attrs.iter().find(|a| crate::attr::name(a) == target_name).filter(|a| crate::attr::list(a)) else {
                return Some(format!("{target_name}: not a declared list attribute"));
            };

            let entities = aggregate.get("entities").map(Json::each).unwrap_or(&[]);
            let Some(entity) = entities.iter().find(|e| e.get("name").and_then(Json::as_str) == Some(crate::attr::type_name(target_attr))) else {
                return Some(format!("{target_name}: remove on a value-object-typed list is not generated yet"));
            };
            let entity_name = entity.get("name").and_then(Json::as_str).unwrap_or("");

            if entity.get("identified_by").map(Json::each).unwrap_or(&[]).len() != 1 {
                return Some(format!("{target_name}: {entity_name}'s identity is composite — remove not generated yet"));
            }

            let Some((id_attr, _)) = entity_identity_mint(entity, value_objects_by_name) else {
                return Some(format!("{target_name}: {entity_name}'s identity isn't a single bridgeable field — remove not generated yet"));
            };

            let source = m.get("source");
            let Some(source) = source.filter(|s| matches!(s, Json::Object(_)) && s.get("kind").map(Json::to_s).unwrap_or_default() == "argument") else {
                return Some(format!("{target_name}: remove sources a literal or record state, not an argument — not generated yet"));
            };

            let source_name = source.get("name").map(Json::to_s).unwrap_or_default();
            let cmd_attrs = command.get("attributes").map(Json::each).unwrap_or(&[]);
            let Some(source_attr) = cmd_attrs.iter().find(|a| crate::attr::name(a) == source_name) else {
                return Some(format!("{target_name}: remove sources undeclared argument {source_name}"));
            };

            let (source_type, id_type) = (crate::attr::type_name(source_attr), crate::attr::type_name(id_attr));
            if !crate::bridging::bridgeable_value_types(source_type, id_type, value_objects_by_name) {
                return Some(format!("{target_name}: {source_type} doesn't bridge to {id_type}"));
            }

            None
        })
        .collect()
}

/// A mutation's `fields` object as ordered `(key, raw_wire_value)` pairs.
fn fields_pairs(fields: &Json) -> Vec<(String, String)> {
    match fields {
        Json::Object(pairs) => pairs.iter().map(|(k, v)| (k.clone(), v.to_s())).collect(),
        _ => Vec::new(),
    }
}

pub struct Transition {
    pub field: String,
    pub to_state: String,
    pub from_states: Vec<String>,
    /// A row with no `from:` admits every state, so no check is emitted for the command.
    pub unconstrained: bool,
}

/// The `Option<TransitionCheck>` expression a dispatch function is generated with.
///
/// `None` covers both "no transition" and an unconstrained one; an empty `from_states` slice
/// would refuse every state instead of admitting every state.
pub fn transition_check_arg(transition: Option<&Transition>) -> String {
    match transition {
        Some(t) if !t.unconstrained => format!(
            "Some(crate::kernel::TransitionCheck {{ field: {}, from_states: &[{}] }})",
            naming::ruby_inspect_string(&t.field),
            t.from_states.iter().map(|s| naming::ruby_inspect_string(s)).collect::<Vec<_>>().join(", ")
        ),
        _ => "None".to_string(),
    }
}

/// Collapses a command's transition rows into the shape `TransitionCheck` wants.
pub fn lifecycle_transition_for(command: &Json, aggregate: &Json) -> Option<Transition> {
    let lifecycle = aggregate.get("lifecycle")?;
    let command_name = command.get("name").map(Json::to_s).unwrap_or_default();
    let transitions = lifecycle.get("transitions").map(Json::each).unwrap_or(&[]);
    let rows: Vec<&Json> = transitions.iter().filter(|t| t.get("command").map(Json::to_s).unwrap_or_default() == command_name).collect();
    if rows.is_empty() {
        // `from:` without a transition guards the current state and moves nothing.
        let froms: Vec<String> = match command.get("from") {
            Some(Json::Null) | None => Vec::new(),
            Some(Json::String(s)) => vec![s.clone()],
            Some(list) => list.each().iter().map(Json::to_s).collect(),
        };
        if froms.is_empty() {
            return None;
        }
        let mut from_states: Vec<String> = Vec::new();
        for from in froms {
            if !from_states.contains(&from) {
                from_states.push(from);
            }
        }
        let field = lifecycle.get("field").and_then(Json::as_str).unwrap_or("").to_string();
        return Some(Transition { field, to_state: String::new(), from_states, unconstrained: false });
    }

    let field = lifecycle.get("field").and_then(Json::as_str).unwrap_or("").to_string();
    let to_state = rows[0].get("to_state").map(Json::to_s).unwrap_or_default();
    let mut from_states: Vec<String> = Vec::new();
    let mut unconstrained = false;
    for row in &rows {
        match row.get_raw("from_state") {
            None | Some(Json::Null) => unconstrained = true,
            Some(from) => {
                let from = from.to_s();
                if !from_states.contains(&from) {
                    from_states.push(from);
                }
            }
        }
    }
    Some(Transition { field, to_state, from_states, unconstrained })
}

/// Right-hand side for a `set`, coercing the source into the target attribute's declared type.
///
/// `target_list` routes list-to-list sets through `list_value_rhs`; `value_rhs` is scalar-only.
pub fn mutation_set_rhs(source: &Json, target_type: &str, command: &Json, value_objects_by_name: &HashMap<String, &Json>, target_list: bool) -> String {
    if source.get("kind").map(Json::to_s).unwrap_or_default() == "literal" {
        let value = source.get("value").unwrap_or(&Json::Null);
        return crate::bridging::literal_rhs_for(&Literal::from_json(value), Some(target_type), value_objects_by_name);
    }

    let source_name = source.get("name").map(Json::to_s).unwrap_or_default();
    // `pre`, not `record`: the pre-dispatch state, bound when `reads_pre_state`.
    if source.get("kind").map(Json::to_s).unwrap_or_default() == "state" {
        return format!("pre.{}.clone()", naming::rust_ident_field(&source_name));
    }
    let cmd_attrs = command.get("attributes").map(Json::each).unwrap_or(&[]);
    let source_attr = cmd_attrs.iter().find(|a| crate::attr::name(a) == source_name).expect("mutation source argument must be a declared command attribute");
    let source_expr = format!("args.{}", naming::rust_ident_field(&source_name));
    if target_list && crate::attr::list(source_attr) && crate::bridging::list_bridge_requires_element_mapping(crate::attr::type_name(source_attr), target_type) {
        return crate::bridging::list_value_rhs(&source_expr, crate::attr::type_name(source_attr), target_type, value_objects_by_name);
    }
    crate::bridging::value_rhs(&source_expr, crate::attr::type_name(source_attr), target_type, value_objects_by_name)
}

pub struct IdentityComponent {
    pub expr: String,
    pub param: Option<String>,
    pub head: Option<String>,
}

/// Builds one component per identity part: a `set` target or same-named command argument reads
/// `args.<head>`, and anything else becomes a parameter.
pub fn identity_components(aggregate: &Json, command: &Json) -> Vec<IdentityComponent> {
    let identified_by = aggregate.get("identified_by").map(Json::each).unwrap_or(&[]);
    let cmd_mutations = command.get("mutations").map(Json::each).unwrap_or(&[]);
    let append_claimed = crate::shared::append_claimed_names(command);
    let declared_names: std::collections::HashSet<String> = command
        .get("attributes")
        .map(Json::each)
        .unwrap_or(&[])
        .iter()
        .map(|a| crate::attr::name(a).to_string())
        .filter(|name| !append_claimed.contains(name))
        .collect();

    identified_by
        .iter()
        .map(|path| {
            let path = path.as_str().unwrap_or("");
            let mut parts = path.split('.');
            let head = parts.next().unwrap_or("");
            let rest: Vec<&str> = parts.collect();

            let set_target = cmd_mutations.iter().any(|m| {
                m.get("op").map(Json::to_s).as_deref() == Some("set") && m.get("target").map(Json::to_s).as_deref() == Some(head)
            });

            if set_target || declared_names.contains(head) {
                if !rest.is_empty() {
                    let rest_path = rest.iter().map(|seg| naming::rust_ident_field(seg)).collect::<Vec<_>>().join(".");
                    IdentityComponent { expr: format!("args.{}.{}.to_string()", naming::rust_ident_field(head), rest_path), param: None, head: None }
                } else {
                    IdentityComponent { expr: format!("args.{}.to_string()", naming::rust_ident_field(head)), param: None, head: None }
                }
            } else {
                let param = naming::rust_ident_field(head);
                IdentityComponent { expr: format!("{param}.to_string()"), param: Some(format!("{param}: &str")), head: Some(head.to_string()) }
            }
        })
        .collect()
}

pub fn build_identity_expr(components: &[IdentityComponent]) -> String {
    if components.len() == 1 {
        return components[0].expr.clone();
    }
    let placeholders = components.iter().map(|_| "{}").collect::<Vec<_>>().join(":");
    format!("format!({}, {})", naming::ruby_inspect_string(&placeholders), components.iter().map(|c| c.expr.as_str()).collect::<Vec<_>>().join(", "))
}

/// The value expression for one `append` field.
pub fn append_field_rhs(source: &str, field_attr: &Json, command: &Json, value_objects_by_name: &HashMap<String, &Json>) -> String {
    let parsed = append_field_source(source);
    let Literal::Symbol(arg_name) = &parsed else {
        return crate::bridging::literal_rhs_for(&parsed, Some(crate::attr::type_name(field_attr)), value_objects_by_name);
    };

    let cmd_attrs = command.get("attributes").map(Json::each).unwrap_or(&[]);
    let arg_attr = cmd_attrs.iter().find(|a| crate::attr::name(a) == arg_name.as_str()).expect("append field argument must be a declared command attribute");
    let arg_expr = format!("args.{}", naming::rust_ident_field(crate::attr::name(arg_attr)));

    if crate::attr::optional(arg_attr) {
        let same_representation = crate::attr::type_name(arg_attr) == crate::attr::type_name(field_attr)
            || match (naming::effective_scalar_type(crate::attr::type_name(arg_attr)), naming::effective_scalar_type(crate::attr::type_name(field_attr))) {
                (Some(a), Some(b)) => a == b,
                _ => false,
            };
        if same_representation {
            return format!("{arg_expr}.clone()");
        }
        return optional_value_rhs(&arg_expr, crate::attr::type_name(arg_attr), crate::attr::type_name(field_attr), value_objects_by_name);
    }

    let rhs = crate::bridging::value_rhs(&arg_expr, crate::attr::type_name(arg_attr), crate::attr::type_name(field_attr), value_objects_by_name);
    if crate::attr::optional(field_attr) {
        format!("Some({rhs})")
    } else {
        rhs
    }
}

/// The optional-source variant of `value_rhs`.
pub fn optional_value_rhs(source_expr: &str, source_type: &str, target_type: &str, value_objects_by_name: &HashMap<String, &Json>) -> String {
    format!("{source_expr}.clone().map(|v| {})", crate::bridging::value_rhs("v", source_type, target_type, value_objects_by_name))
}

/// Emits the closure line for one mutation.
pub fn emit_mutation_line(exemplar: &Exemplar, mutation: &Json, aggregate: &Json, command: &Json, value_objects_by_name: &HashMap<String, &Json>, optional: bool) -> String {
    let target_field = naming::rust_ident_field(&mutation.get("target").map(Json::to_s).unwrap_or_default());
    let lifecycle_field = aggregate.get("lifecycle").and_then(|l| l.get("field")).map(Json::to_s);
    format!("        {}", emit_mutation_line_body(exemplar, mutation, aggregate, command, value_objects_by_name, &target_field, lifecycle_field.as_deref(), optional))
}

fn emit_mutation_line_body(
    exemplar: &Exemplar,
    mutation: &Json,
    aggregate: &Json,
    command: &Json,
    value_objects_by_name: &HashMap<String, &Json>,
    target_field: &str,
    lifecycle_field: Option<&str>,
    optional: bool,
) -> String {
    let op = mutation.get("op").map(Json::to_s).unwrap_or_default();
    let target_name = mutation.get("target").map(Json::to_s).unwrap_or_default();

    match op.as_str() {
        "append" => {
            let attrs = aggregate.get("attributes").map(Json::each).unwrap_or(&[]);
            let target_attr = attrs.iter().find(|a| crate::attr::name(a) == target_name).expect("append target must be a declared aggregate attribute");
            let vo_type = naming::rust_ident(crate::attr::type_name(target_attr));
            let entity = aggregate.get("entities").map(Json::each).unwrap_or(&[]).iter().find(|e| e.get("name").and_then(Json::as_str) == Some(crate::attr::type_name(target_attr)));
            let element = entity.or_else(|| value_objects_by_name.get(crate::attr::type_name(target_attr)).copied()).expect("append target's element type must resolve");

            let fields = mutation.get("fields").map(fields_pairs).unwrap_or_default();
            let element_attrs = element.get("attributes").map(Json::each).unwrap_or(&[]);
            let mut fields_assignment: Vec<String> = fields
                .iter()
                .map(|(field_name, source)| {
                    let field_attr = element_attrs.iter().find(|a| crate::attr::name(a) == field_name.as_str()).expect("append field must be a declared element attribute");
                    format!("{}: {}", naming::rust_ident_field(field_name), append_field_rhs(source, field_attr, command, value_objects_by_name))
                })
                .collect();

            let mut collision_guard = String::new();
            if let Some(entity) = entity {
                let mut present: Vec<String> = fields.iter().map(|(k, _)| k.clone()).collect();
                let identified_by = entity.get("identified_by").map(Json::each).unwrap_or(&[]);
                if identified_by.len() > 1 {
                    // Composite identity: minting a partial key makes no sense, so every head must
                    // already be caller-supplied (as `Venue.AddLine`'s `append: { batch: :batch,
                    // sequence: :sequence }` does). Refuse a duplicate across the WHOLE tuple, the
                    // way `EntityElement.check_entity_collision`'s `heads.all?` does — this branch
                    // used to be skipped outright for any composite identity (its comment read
                    // "Composite identities are excluded"), so two elements sharing every identity
                    // component went through unrefused. Root cause of this bug.
                    let heads: Vec<String> = identified_by.iter().map(|p| p.to_s().split('.').next().unwrap_or_default().to_string()).collect();
                    if heads.iter().all(|h| present.iter().any(|p| p == h)) {
                        collision_guard = composite_append_collision_guard(&heads, &fields, element_attrs, command, value_objects_by_name, target_field, entity, aggregate, identified_by);
                    }
                } else if let Some((id_attr, id_vo)) = entity_identity_mint(entity, value_objects_by_name) {
                    let id_name = crate::attr::name(id_attr);
                    if !present.iter().any(|p| p == id_name) {
                        let id_vo_attrs = id_vo.get("attributes").map(Json::each).unwrap_or(&[]);
                        // Mint one past the highest identity held.
                        let id_field = naming::rust_ident_field(id_name);
                        let vo_field = naming::rust_ident_field(crate::attr::name(&id_vo_attrs[0]));
                        let mint = format!(
                            "{} {{ {vo_field}: record.{target_field}.iter().map(|e| e.{id_field}.{vo_field}).max().unwrap_or(0) + 1 }}",
                            naming::rust_ident(crate::attr::type_name(id_attr)),
                        );
                        fields_assignment.push(format!("{}: {mint}", naming::rust_ident_field(id_name)));
                        present.push(id_name.to_string());
                    } else {
                        // Caller-supplied single-field identity: refuse a duplicate, which would
                        // be unaddressable later.
                        let id_field = naming::rust_ident_field(id_name);
                        let id_rhs = fields
                            .iter()
                            .find(|(k, _)| k == id_name)
                            .map(|(_, source)| {
                                let field_attr = element_attrs
                                    .iter()
                                    .find(|a| crate::attr::name(a) == id_name)
                                    .expect("append field must be a declared element attribute");
                                append_field_rhs(source, field_attr, command, value_objects_by_name)
                            })
                            .expect("caller-supplied identity field must be in the append's own field map");
                        let entity_name = entity.get("name").and_then(Json::as_str).unwrap_or_default();
                        let aggregate_name = aggregate.get("name").and_then(Json::as_str).unwrap_or_default();
                        let identity_reading = identified_by.iter().map(Json::to_s).collect::<Vec<_>>().join(", ");
                        let entity_lit = naming::ruby_inspect_string(entity_name);
                        let aggregate_lit = naming::ruby_inspect_string(aggregate_name);
                        let identity_lit = naming::ruby_inspect_string(&identity_reading);
                        // Unwrap to the bare scalar, as `entity_list_replace_guard` does; the mint
                        // branch above guarantees exactly one attribute.
                        let offered_field = naming::rust_ident_field(crate::attr::name(&id_vo.get("attributes").map(Json::each).unwrap_or(&[])[0]));
                        let offered_expr = format!("{id_rhs}.{offered_field}");
                        collision_guard = format!(
                            "if record.{target_field}.iter().any(|e| e.{id_field} == {id_rhs}) {{ let offered = format!(\"{{:?}}\", {offered_expr}); return Err(crate::kernel::Refusal::AlreadyExists(crate::kernel::refusal_wording::AlreadyExistsEntityDuplicateArgs {{ entity: {entity_lit}, aggregate: {aggregate_lit}, identity: {identity_lit}, offered: &[offered.as_str()] }}.render_args())); }}\n        "
                        );
                    }
                }
                if let Some(entity_lifecycle) = entity.get("lifecycle") {
                    let lc_field = entity_lifecycle.get("field").map(Json::to_s).unwrap_or_default();
                    if !present.iter().any(|p| p == &lc_field) {
                        let default = entity_lifecycle.get("default").map(Json::to_s).unwrap_or_default();
                        fields_assignment.push(format!("{}: {}.to_string()", naming::rust_ident_field(&lc_field), naming::ruby_inspect_string(&default)));
                        present.push(lc_field);
                    }
                }

                // Fill list attributes no `append:` names; a later command appends to them.
                for attr in element_attrs {
                    if !crate::attr::list(attr) {
                        continue;
                    }
                    let attr_name = crate::attr::name(attr);
                    if present.iter().any(|p| p == attr_name) {
                        continue;
                    }
                    fields_assignment.push(format!("{}: Vec::new()", naming::rust_ident_field(attr_name)));
                    present.push(attr_name.to_string());
                }

                // Fill optional scalars no `append:` names; a later command sets them.
                for attr in element_attrs {
                    if crate::attr::list(attr) || !crate::attr::optional(attr) {
                        continue;
                    }
                    let attr_name = crate::attr::name(attr);
                    if present.iter().any(|p| p == attr_name) {
                        continue;
                    }
                    fields_assignment.push(format!("{}: None", naming::rust_ident_field(attr_name)));
                    present.push(attr_name.to_string());
                }
            }

            format!("{collision_guard}{}", exemplar.render("mutation_append", &[("tmpl_field", target_field.to_string()), ("tmpl_fields_placeholder()", format!("{vo_type} {{ {} }}", fields_assignment.join(", ")))]))
        }
        "set" => {
            if lifecycle_field.map(|f| f == target_name).unwrap_or(false) {
                let rhs = mutation_set_rhs(mutation.get("source").unwrap_or(&Json::Null), "String", command, value_objects_by_name, false);
                exemplar.render("mutation_set_plain", &[("tmpl_field", target_field.to_string()), ("tmpl_rhs_placeholder2()", rhs)])
            } else {
                let attrs = aggregate.get("attributes").map(Json::each).unwrap_or(&[]);
                let target_attr = attrs.iter().find(|a| crate::attr::name(a) == target_name).expect("set target must be a declared aggregate attribute");
                let rhs = mutation_set_rhs(mutation.get("source").unwrap_or(&Json::Null), crate::attr::type_name(target_attr), command, value_objects_by_name, crate::attr::list(target_attr));
                let source = mutation.get("source");
                let source_attr = if source.map(|s| s.get("kind").map(Json::to_s).unwrap_or_default()) == Some("argument".to_string()) {
                    let name = source.unwrap().get("name").map(Json::to_s).unwrap_or_default();
                    let cmd_attrs = command.get("attributes").map(Json::each).unwrap_or(&[]);
                    cmd_attrs.iter().find(|a| crate::attr::name(a) == name)
                } else {
                    None
                };

                if crate::attr::list(target_attr) && optional && crate::shared::list_attr_creation_optional(aggregate, crate::attr::name(target_attr), value_objects_by_name) {
                    exemplar.render("mutation_set_plain", &[("tmpl_field", target_field.to_string()), ("tmpl_rhs_placeholder2()", rhs)])
                } else if crate::attr::list(target_attr) && source_attr.map(crate::attr::optional).unwrap_or(false) {
                    exemplar.render("mutation_set_unwrap_or_default", &[("tmpl_field", target_field.to_string()), ("tmpl_optional_rhs_placeholder()", rhs)])
                } else if crate::attr::list(target_attr) {
                    // Only whole-list replaces carry the duplicate-identity guard.
                    let (guard, effective_rhs) = entity_list_replace_guard(aggregate, target_attr, &target_field, &rhs, value_objects_by_name);
                    format!("{guard}{}", exemplar.render("mutation_set_plain", &[("tmpl_field", target_field.to_string()), ("tmpl_rhs_placeholder2()", effective_rhs)]))
                } else {
                    let wrap = (optional || crate::attr::optional(target_attr)) && !source_attr.map(crate::attr::optional).unwrap_or(false);
                    if wrap {
                        exemplar.render("mutation_set_wrapped", &[("tmpl_field", target_field.to_string()), ("tmpl_rhs_placeholder2()", rhs)])
                    } else {
                        exemplar.render("mutation_set_plain", &[("tmpl_field", target_field.to_string()), ("tmpl_rhs_placeholder2()", rhs)])
                    }
                }
            }
        }
        "increment" | "decrement" => {
            let (target_attr, integer_field) = crate::bridging::arithmetic_target_field(mutation, aggregate, value_objects_by_name).expect("arithmetic target must resolve");
            let vo_type = naming::rust_ident(crate::attr::type_name(target_attr));
            let field_ident = naming::rust_ident_field(&integer_field);
            let amount_expr = crate::bridging::arithmetic_amount_expr(mutation.get("source").unwrap_or(&Json::Null), command, value_objects_by_name, &integer_field).expect("arithmetic amount must resolve");
            // Use the IR's `sign`, not the op name.
            let sign = if mutation.get("sign").map(Json::to_s).unwrap_or_default() == "1" { "+" } else { "-" };
            let current = if optional { format!("record.{target_field}.clone().unwrap()") } else { format!("record.{target_field}.clone()") };
            let op = mutation.get("op").map(Json::to_s).unwrap_or_default();
            let updated = format!("{vo_type} {{ {field_ident}: {}, ..current }}", checked_arithmetic(&op, &field_ident, sign, &amount_expr));
            exemplar.render(
                "mutation_arithmetic",
                &[("tmpl_field", target_field.to_string()), ("tmpl_current_placeholder()", current), ("tmpl_updated_placeholder()", if optional { format!("Some({updated})") } else { updated })],
            )
        }
        "multiply" => {
            // Same Integer-field subset as `increment`/`decrement`, with `*`.
            let (target_attr, integer_field) = crate::bridging::arithmetic_target_field(mutation, aggregate, value_objects_by_name).expect("arithmetic target must resolve");
            let vo_type = naming::rust_ident(crate::attr::type_name(target_attr));
            let field_ident = naming::rust_ident_field(&integer_field);
            let amount_expr = crate::bridging::arithmetic_amount_expr(mutation.get("source").unwrap_or(&Json::Null), command, value_objects_by_name, &integer_field).expect("arithmetic amount must resolve");
            let current = if optional { format!("record.{target_field}.clone().unwrap()") } else { format!("record.{target_field}.clone()") };
            let updated = format!("{vo_type} {{ {field_ident}: {}, ..current }}", checked_arithmetic("multiply", &field_ident, "*", &amount_expr));
            exemplar.render(
                "mutation_arithmetic",
                &[("tmpl_field", target_field.to_string()), ("tmpl_current_placeholder()", current), ("tmpl_updated_placeholder()", if optional { format!("Some({updated})") } else { updated })],
            )
        }
        "clamp" => {
            // The source is always a literal `[min, max]` pair, so there is no amount to resolve.
            let (target_attr, integer_field) = crate::bridging::arithmetic_target_field(mutation, aggregate, value_objects_by_name).expect("clamp target must resolve");
            let vo_type = naming::rust_ident(crate::attr::type_name(target_attr));
            let field_ident = naming::rust_ident_field(&integer_field);
            let (min, max) = mutation.get("source").and_then(crate::bridging::clamp_bounds_ints).expect("clamp bounds must resolve");
            let current = if optional { format!("record.{target_field}.clone().unwrap()") } else { format!("record.{target_field}.clone()") };
            let updated = format!("{vo_type} {{ {field_ident}: current.{field_ident}.clamp({min}, {max}), ..current }}");
            exemplar.render(
                "mutation_arithmetic",
                &[("tmpl_field", target_field.to_string()), ("tmpl_current_placeholder()", current), ("tmpl_updated_placeholder()", if optional { format!("Some({updated})") } else { updated })],
            )
        }
        "remove" => {
            // `remove_field_problems` already confirmed every lookup below resolves.
            let attrs = aggregate.get("attributes").map(Json::each).unwrap_or(&[]);
            let target_attr = attrs.iter().find(|a| crate::attr::name(a) == target_name).expect("remove target must be a declared aggregate attribute");
            let entities = aggregate.get("entities").map(Json::each).unwrap_or(&[]);
            let entity = entities.iter().find(|e| e.get("name").and_then(Json::as_str) == Some(crate::attr::type_name(target_attr))).expect("remove target must be an entity-typed list");
            let (id_attr, _) = entity_identity_mint(entity, value_objects_by_name).expect("remove target entity's identity must mint");
            let id_field = naming::rust_ident_field(crate::attr::name(id_attr));
            let source_name = mutation.get("source").and_then(|s| s.get("name")).map(Json::to_s).unwrap_or_default();
            let cmd_attrs = command.get("attributes").map(Json::each).unwrap_or(&[]);
            let source_attr = cmd_attrs.iter().find(|a| crate::attr::name(a) == source_name).expect("remove source must be a declared argument");
            let match_expr = crate::bridging::value_rhs(
                &format!("args.{}", naming::rust_ident_field(crate::attr::name(source_attr))),
                crate::attr::type_name(source_attr),
                crate::attr::type_name(id_attr),
                value_objects_by_name,
            );
            exemplar.render("mutation_remove", &[("tmpl_field", target_field.to_string()), ("tmpl_id_field", id_field), ("tmpl_remove_match_placeholder()", match_expr)])
        }
        // `corrects` targets no field; entity-level commands do not filter it out first.
        "corrects" => String::new(),
        other => panic!("unsupported mutation op {other:?} — command_skip_reason should have caught this"),
    }
}

#[cfg(test)]
mod transition_tests {
    use super::*;

    fn aggregate(rows: &str) -> Json {
        Json::parse(&format!(
            r#"{{"name":"Account","lifecycle":{{"field":"status","default":"draft","transitions":[{rows}]}}}}"#
        ))
        .unwrap()
    }

    fn command(name: &str) -> Json {
        Json::parse(&format!(r#"{{"name":"{name}"}}"#)).unwrap()
    }

    #[test]
    fn a_transition_without_from_admits_every_state() {
        let account = aggregate(r#"{"command":"Open","to_state":"open","from_state":null}"#);
        let transition = lifecycle_transition_for(&command("Open"), &account).unwrap();
        assert!(transition.unconstrained);
        assert_eq!(transition.to_state, "open");
        assert_eq!(transition_check_arg(Some(&transition)), "None");
    }

    #[test]
    fn a_transition_with_from_checks_that_state() {
        let account = aggregate(r#"{"command":"Close","to_state":"closed","from_state":"open"}"#);
        let transition = lifecycle_transition_for(&command("Close"), &account).unwrap();
        assert!(!transition.unconstrained);
        assert_eq!(
            transition_check_arg(Some(&transition)),
            r#"Some(crate::kernel::TransitionCheck { field: "status", from_states: &["open"] })"#
        );
    }

    #[test]
    fn one_unconstrained_row_among_constrained_ones_admits_every_state() {
        let account = aggregate(
            r#"{"command":"Reopen","to_state":"open","from_state":"closed"},
               {"command":"Reopen","to_state":"open","from_state":null}"#,
        );
        let transition = lifecycle_transition_for(&command("Reopen"), &account).unwrap();
        assert_eq!(transition_check_arg(Some(&transition)), "None");
    }
}
