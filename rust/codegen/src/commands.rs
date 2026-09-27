//! Port of `rust/project/commands.rb`: emits the per-command dispatch functions.

use crate::exemplar::Exemplar;
use crate::json::Json;
use crate::literal::Literal;
use crate::mutations;
use crate::naming;
use crate::skip_reason::{skip, SkipReason};
use std::collections::HashMap;

/// The aggregate's invariant set, generated once per aggregate file and passed to every dispatch.
pub fn invariants_fn_name(aggregate: &Json) -> String {
    format!("{}_invariants", naming::rust_ident_field(aggregate.get("name").and_then(Json::as_str).unwrap_or("")).to_lowercase())
}

pub fn emit_invariants_fn(aggregate: &Json) -> String {
    let aggregate_vec = invariant_specs_vec(aggregate.get("invariants").map(Json::each).unwrap_or(&[]), 8);
    let entities_vec = entity_invariants_vec(aggregate, 8);
    // `Expr` is imported only when an invariant literal was emitted; otherwise it is unused.
    let needs_expr = aggregate_vec.contains("Expr::") || entities_vec.contains("Expr::");
    [
        Some(format!("fn {}() -> crate::kernel::InvariantSet {{", invariants_fn_name(aggregate))),
        needs_expr.then(|| "    use crate::kernel::Expr;".to_string()),
        Some("    crate::kernel::InvariantSet {".to_string()),
        Some(format!("        aggregate: {aggregate_vec},")),
        Some(format!("        entities: {entities_vec},")),
        Some("    }".to_string()),
        Some("}".to_string()),
    ]
    .into_iter()
    .flatten()
    .collect::<Vec<_>>()
    .join("\n")
}

fn invariant_specs_vec(rules: &[Json], indent: usize) -> String {
    if rules.is_empty() {
        return "vec![]".to_string();
    }
    let pad = " ".repeat(indent + 4);
    let rows: Vec<String> = rules
        .iter()
        .map(|rule| {
            let description = rule.get("description").and_then(Json::as_str).unwrap_or("");
            let ast = rule.get("ast").unwrap_or_else(|| panic!("invariant row has no ast: {rule:?}"));
            format!(
                "{pad}crate::kernel::InvariantSpec {{ description: {}, expr: {} }},",
                naming::ruby_inspect_string(description),
                crate::expr_emitter::emit_ast(ast)
            )
        })
        .collect();
    format!("vec![\n{}\n{}]", rows.join("\n"), " ".repeat(indent))
}

fn entity_invariants_vec(owner: &Json, indent: usize) -> String {
    let entities = owner.get("entities").map(Json::each).unwrap_or(&[]);
    let attributes = owner.get("attributes").map(Json::each).unwrap_or(&[]);
    let pieces: Vec<(&Json, String)> = entities
        .iter()
        .filter_map(|entity| {
            if entity.get("invariants").map(Json::each).unwrap_or(&[]).is_empty() {
                return None;
            }
            let name = entity.get("name").map(Json::to_s).unwrap_or_default();
            let list = attributes
                .iter()
                .find(|a| a.get("list").map(Json::as_bool).unwrap_or(false) && a.get("type").map(Json::to_s).unwrap_or_default() == name)?;
            Some((entity, list.get("name").map(Json::to_s).unwrap_or_default()))
        })
        .collect();
    if pieces.is_empty() {
        return "vec![]".to_string();
    }
    let pad = " ".repeat(indent + 4);
    let rows: Vec<String> = pieces
        .iter()
        .map(|(entity, list_field)| {
            format!(
                "{pad}crate::kernel::EntityInvariants {{ name: {}, list_field: {}, specs: {}, nested: {} }},",
                naming::ruby_inspect_string(&entity.get("name").map(Json::to_s).unwrap_or_default()),
                naming::ruby_inspect_string(list_field),
                invariant_specs_vec(entity.get("invariants").map(Json::each).unwrap_or(&[]), indent + 4),
                entity_invariants_vec(entity, indent + 4)
            )
        })
        .collect();
    format!("vec![\n{}\n{}]", rows.join("\n"), " ".repeat(indent))
}

/// Extra parameters of every generated `dispatch_*`/`dispatch_entity_*`, resolved by the router.
fn deref_params() -> [&'static str; 2] {
    ["owner_deref: Vec<(&'static str, crate::kernel::DerefNode)>", "command_deref: Vec<(&'static str, crate::kernel::DerefNode)>"]
}

/// Write-side tenant boundary result, threaded through aggregate commands only.
/// The router always passes `Ok(())`: no domain generated from `ir.json` declares a boundary.
const TENANT_BOUNDARY_PARAM: &str = "tenant_boundary_check: Result<(), crate::kernel::Refusal>";

fn with_references_binding() -> String {
    "let with_references = crate::kernel::WithReferences { command_deref: &command_deref, args: &args, owner_deref: &owner_deref };".to_string()
}

/// Binds the synchronous half of `projects` (ADR 0025).
fn seed_projections_binding(aggregate: &Json) -> String {
    let table = naming::screaming_snake(aggregate.get("name").and_then(Json::as_str).unwrap_or(""));
    format!("let seed_projections = crate::kernel::seeded_projections(&with_references, {table}_PROJECTED_FIELDS);")
}

fn target_type_for<'a>(target: &str, aggregate: &'a Json, lifecycle_field: Option<&str>) -> Option<&'a str> {
    if lifecycle_field == Some(target) {
        return Some("String");
    }
    let attrs = aggregate.get("attributes").map(Json::each).unwrap_or(&[]);
    attrs.iter().find(|a| crate::attr::name(a) == target).map(crate::attr::type_name)
}

// The lifecycle field is never a list; `false` when the target is not found.
fn target_list_for(target: &str, aggregate: &Json, lifecycle_field: Option<&str>) -> bool {
    if lifecycle_field == Some(target) {
        return false;
    }
    let attrs = aggregate.get("attributes").map(Json::each).unwrap_or(&[]);
    attrs.iter().find(|a| crate::attr::name(a) == target).map(crate::attr::list).unwrap_or(false)
}

pub fn command_skip_reason(command: &Json, aggregate: &Json, value_objects_by_name: &HashMap<String, &Json>) -> Option<SkipReason> {
    command_skip_reason_with(command, aggregate, value_objects_by_name, true)
}

/// `creating_possible` is false for an entity command: its optional identity argument is not an
/// identity source.
fn command_skip_reason_with(command: &Json, aggregate: &Json, value_objects_by_name: &HashMap<String, &Json>, creating_possible: bool) -> Option<SkipReason> {
    let mutations_list = command.get("mutations").map(Json::each).unwrap_or(&[]);

    let mut unsupported_ops: Vec<String> = Vec::new();
    for m in mutations_list {
        let op = m.get("op").map(Json::to_s).unwrap_or_default();
        // `remove` passes here; `mutations::remove_field_problems` narrows it to entity lists.
        if !["append", "set", "increment", "decrement", "multiply", "clamp", "remove", "delegate", "corrects"].contains(&op.as_str()) && !unsupported_ops.contains(&op) {
            unsupported_ops.push(op);
        }
    }
    if !unsupported_ops.is_empty() {
        return Some(skip("mutation_op", format!("sets op(s) {} not generated yet (only append/set/increment/decrement/multiply/clamp/remove/delegate/corrects are)", unsupported_ops.join(", "))));
    }

    if let Some(corrects) = crate::bridging::corrects_of(command) {
        // The IR is already derived, so only a command carrying nothing but its `corrects` is
        // refused.
        if crate::bridging::corrects_reverses(corrects) && mutations_list.iter().all(|m| m.get("op").map(Json::to_s).unwrap_or_default() == "corrects") {
            let event = corrects.get("target").map(Json::to_s).unwrap_or_default();
            return Some(skip("corrects_reverses", format!("corrects {event}, reverses: true — the derived append/remove-reversal shape is a real, separate gap Ruby's own authors haven't finished designing (AggregateBuilder#seal_correction_targets's own comment) — not generated yet")));
        }
    }

    if let Some(problem) = delegate_skip_reason(command, aggregate, value_objects_by_name) {
        return Some(skip("delegate", problem));
    }

    let append_problems = mutations::append_field_problems(command, aggregate, value_objects_by_name);
    if !append_problems.is_empty() {
        return Some(skip("append_field", format!("sets append field(s): {}", append_problems.join("; "))));
    }

    let state_problems = mutations::state_source_problems(command, aggregate, value_objects_by_name);
    if !state_problems.is_empty() {
        return Some(skip("state_source", format!("sets state source(s): {}", state_problems.join("; "))));
    }

    let remove_problems = mutations::remove_field_problems(command, aggregate, value_objects_by_name);
    if !remove_problems.is_empty() {
        return Some(skip("remove_field", format!("sets remove field(s): {}", remove_problems.join("; "))));
    }

    let lifecycle_field = aggregate.get("lifecycle").and_then(|l| l.get("field")).map(Json::to_s);

    let literal_set_targets: Vec<String> = mutations_list
        .iter()
        .filter(|m| {
            if m.get("op").map(Json::to_s).unwrap_or_default() != "set" {
                return false;
            }
            let Some(source) = m.get("source") else { return false };
            if source.get("kind").map(Json::to_s).unwrap_or_default() != "literal" {
                return false;
            }
            let value = source.get("value").unwrap_or(&Json::Null);
            let target = m.get("target").map(Json::to_s).unwrap_or_default();
            let target_type = target_type_for(&target, aggregate, lifecycle_field.as_deref());
            !crate::bridging::literal_set_bridgeable(&Literal::from_json(value), target_type, value_objects_by_name)
        })
        .map(|m| m.get("target").map(Json::to_s).unwrap_or_default())
        .collect();
    if !literal_set_targets.is_empty() {
        return Some(skip("set_literal", format!("sets to: a literal that doesn't bridge to the target's type ({}) — not generated yet", literal_set_targets.join(", "))));
    }

    let mismatched_sets: Vec<String> = mutations_list
        .iter()
        .filter(|m| {
            if m.get("op").map(Json::to_s).unwrap_or_default() != "set" {
                return false;
            }
            let Some(source) = m.get("source") else { return false };
            if source.get("kind").map(Json::to_s).unwrap_or_default() != "argument" {
                return false;
            }
            let target = m.get("target").map(Json::to_s).unwrap_or_default();
            let target_type = target_type_for(&target, aggregate, lifecycle_field.as_deref());
            let source_name = source.get("name").map(Json::to_s).unwrap_or_default();
            let cmd_attrs = command.get("attributes").map(Json::each).unwrap_or(&[]);
            let source_attr = cmd_attrs.iter().find(|a| crate::attr::name(a) == source_name);
            let source_type = source_attr.map(crate::attr::type_name);
            // List-ness must match too: element-type bridging alone would collapse a `Vec` to a
            // scalar.
            match (target_type, source_type, source_attr) {
                (Some(t), Some(s), Some(source_attr)) => {
                    target_list_for(&target, aggregate, lifecycle_field.as_deref()) != crate::attr::list(source_attr)
                        || !crate::bridging::bridgeable_value_types(s, t, value_objects_by_name)
                }
                _ => false,
            }
        })
        .map(|m| m.get("target").map(Json::to_s).unwrap_or_default())
        .collect();
    if !mismatched_sets.is_empty() {
        return Some(skip("set_argument_bridge", format!("sets :{} sources an argument no single-field rewrap can bridge to the target's type — not generated yet", mismatched_sets.join(", "))));
    }

    let arithmetic_targets: Vec<&Json> = mutations_list.iter().filter(|m| ["increment", "decrement", "multiply"].contains(&m.get("op").map(Json::to_s).unwrap_or_default().as_str())).collect();
    let unsupported_arithmetic: Vec<String> = arithmetic_targets
        .iter()
        .filter(|m| {
            let target = crate::bridging::arithmetic_target_field(m, aggregate, value_objects_by_name);
            match target {
                Some((_, field)) => crate::bridging::arithmetic_amount_expr(m.get("source").unwrap_or(&Json::Null), command, value_objects_by_name, &field).is_none(),
                None => true,
            }
        })
        .map(|m| m.get("target").map(Json::to_s).unwrap_or_default())
        .collect();
    if !unsupported_arithmetic.is_empty() {
        return Some(skip("arithmetic", format!("sets :{} increment/decrement/multiply amount or target field isn't bridgeable — not generated yet", unsupported_arithmetic.join(", "))));
    }

    // `:clamp`: target as for increment/decrement/multiply; bounds via `clamp_bounds_ints`.
    let clamp_targets: Vec<&Json> = mutations_list.iter().filter(|m| m.get("op").map(Json::to_s).unwrap_or_default() == "clamp").collect();
    let unsupported_clamp: Vec<String> = clamp_targets
        .iter()
        .filter(|m| {
            let target = crate::bridging::arithmetic_target_field(m, aggregate, value_objects_by_name);
            let bounds = m.get("source").and_then(crate::bridging::clamp_bounds_ints);
            target.is_none() || bounds.is_none()
        })
        .map(|m| m.get("target").map(Json::to_s).unwrap_or_default())
        .collect();
    if !unsupported_clamp.is_empty() {
        return Some(skip("clamp", format!("sets :{} clamp target field or bounds isn't bridgeable — not generated yet", unsupported_clamp.join(", "))));
    }

    let optional_problems = optional_source_mismatches_with(command, aggregate, value_objects_by_name, creating_possible);
    if !optional_problems.is_empty() {
        return Some(skip("optional_source", format!("optional argument feeds a non-optional target: {} — not generated yet", optional_problems.join("; "))));
    }

    None
}

pub fn optional_source_mismatches(command: &Json, aggregate: &Json, value_objects_by_name: &HashMap<String, &Json>) -> Vec<String> {
    optional_source_mismatches_with(command, aggregate, value_objects_by_name, true)
}

fn optional_source_mismatches_with(command: &Json, aggregate: &Json, value_objects_by_name: &HashMap<String, &Json>, creating_possible: bool) -> Vec<String> {
    let lifecycle_field = aggregate.get("lifecycle").and_then(|l| l.get("field")).map(Json::to_s);
    let mut problems: Vec<String> = Vec::new();
    let cmd_attrs = command.get("attributes").map(Json::each).unwrap_or(&[]);

    if creating_possible && crate::shared::creates_owner(aggregate, command, value_objects_by_name) {
        let identified_by = aggregate.get("identified_by").map(Json::each).unwrap_or(&[]);
        for path in identified_by {
            let path = path.as_str().unwrap_or("");
            let head = path.split('.').next().unwrap_or("");
            if let Some(source_attr) = cmd_attrs.iter().find(|a| crate::attr::name(a) == head) {
                if crate::attr::optional(source_attr) {
                    problems.push(format!("identified_by :{path} sources optional argument {}", crate::attr::name(source_attr)));
                }
            }
        }
    }

    let mutations_list = command.get("mutations").map(Json::each).unwrap_or(&[]);
    for m in mutations_list {
        let op = m.get("op").map(Json::to_s).unwrap_or_default();
        let target = m.get("target").map(Json::to_s).unwrap_or_default();
        match op.as_str() {
            "set" => {
                let Some(source) = m.get("source") else { continue };
                if source.get("kind").map(Json::to_s).unwrap_or_default() != "argument" {
                    continue;
                }
                let source_name = source.get("name").map(Json::to_s).unwrap_or_default();
                let Some(source_attr) = cmd_attrs.iter().find(|a| crate::attr::name(a) == source_name) else { continue };
                if !crate::attr::optional(source_attr) {
                    continue;
                }

                if lifecycle_field.as_deref() == Some(target.as_str()) {
                    problems.push(format!("sets :{target} sources optional argument {} into the lifecycle field", crate::attr::name(source_attr)));
                    continue;
                }

                let attrs = aggregate.get("attributes").map(Json::each).unwrap_or(&[]);
                let target_attr = attrs.iter().find(|a| crate::attr::name(a) == target);
                if target_attr.map(crate::attr::list).unwrap_or(false) {
                    continue;
                }
                // An aggregate command's record fields are all `Option<T>`.
                if creating_possible {
                    continue;
                }
                if !target_attr.map(crate::attr::optional).unwrap_or(false) {
                    problems.push(format!("sets :{target} sources optional argument {}", crate::attr::name(source_attr)));
                }
            }
            "append" => {
                let attrs = aggregate.get("attributes").map(Json::each).unwrap_or(&[]);
                let Some(target_attr) = attrs.iter().find(|a| crate::attr::name(a) == target) else { continue };
                let Some(element) = mutations::append_element(aggregate, crate::attr::type_name(target_attr), value_objects_by_name) else { continue };

                let fields = match m.get("fields") {
                    Some(Json::Object(pairs)) => pairs.clone(),
                    _ => Vec::new(),
                };
                let element_attrs = element.get("attributes").map(Json::each).unwrap_or(&[]);
                for (field_name, source) in &fields {
                    let parsed = mutations::append_field_source(&source.to_s());
                    let Literal::Symbol(arg_name) = &parsed else { continue };
                    let Some(source_attr) = cmd_attrs.iter().find(|a| crate::attr::name(a) == arg_name.as_str()) else { continue };
                    if !crate::attr::optional(source_attr) {
                        continue;
                    }
                    let field_attr = element_attrs.iter().find(|a| crate::attr::name(a) == field_name.as_str());
                    if !field_attr.map(crate::attr::optional).unwrap_or(false) {
                        problems.push(format!("sets append {target}.{field_name} sources optional argument {}", crate::attr::name(source_attr)));
                    }
                }
            }
            _ => {}
        }
    }

    problems
}

/// One attribute's `admits:` check and value-object invariant check against `value_expr`.
/// `pattern:` is not checked: Ruby never enforces it on a bare command attribute (ADR 0051).
/// List attributes get no `admits:` check either, matching Ruby.
pub fn argument_check_lines(exemplar: &Exemplar, attr: &Json, value_expr: &str, aggregates_by_name: &HashMap<String, &Json>, value_objects_by_name: &HashMap<String, &Json>) -> Vec<String> {
    let mut lines: Vec<String> = Vec::new();

    if !crate::attr::list(attr) {
        // Raw field expression: `constraints.rs` handles optionals itself.
        if let Some(c) = crate::constraints::emit_admits_check(exemplar, value_expr, attr, aggregates_by_name, value_objects_by_name) {
            lines.push(format!("        {c}"));
        }
    }

    let vo = value_objects_by_name.get(crate::attr::type_name(attr));
    if let Some(vo) = vo {
        if !vo.get("closed_set").map(Json::as_bool).unwrap_or(false) {
            let line = if crate::attr::optional(attr) {
                if crate::attr::list(attr) {
                    format!("        if let Some(items) = &{value_expr} {{ for item in items {{ item.check_invariants()?; }} }}")
                } else {
                    format!("        if let Some(v) = &{value_expr} {{ v.check_invariants()?; }}")
                }
            } else if crate::attr::list(attr) {
                format!("        for item in &{value_expr} {{ item.check_invariants()?; }}")
            } else {
                format!("        {value_expr}.check_invariants()?;")
            };
            lines.push(line);
        }
    }

    lines
}

/// Invariant checks against the built `args.{field}`, redundant with `emit_from_json_flat`'s copy.
pub fn invariant_checks_for(exemplar: &Exemplar, command: &Json, aggregates_by_name: &HashMap<String, &Json>, value_objects_by_name: &HashMap<String, &Json>) -> Vec<String> {
    let attrs = command.get("attributes").map(Json::each).unwrap_or(&[]);
    let mut lines: Vec<String> = Vec::new();

    for attr in attrs {
        let field = naming::rust_ident_field(crate::attr::name(attr));
        let value_expr = format!("args.{field}");
        lines.extend(argument_check_lines(exemplar, attr, &value_expr, aggregates_by_name, value_objects_by_name));
    }

    lines
}

/// One emitter for every command shape `kernel::dispatch` can run.
pub fn emit_command(exemplar: &Exemplar, command: &Json, aggregate: &Json, domain_name: &str, value_objects_by_name: &HashMap<String, &Json>, aggregates_by_name: &HashMap<String, &Json>) -> String {
    let record = naming::rust_ident(aggregate.get("name").and_then(Json::as_str).unwrap_or(""));
    let cmd = naming::rust_ident(command.get("name").and_then(Json::as_str).unwrap_or(""));
    let creates = crate::shared::creates_owner(aggregate, command, value_objects_by_name);
    let identity = mutations::identity_components(aggregate, command);
    let identity_extra_params: Vec<String> = identity.iter().filter_map(|c| c.param.clone()).collect();

    let aggregate_name = aggregate.get("name").and_then(Json::as_str).unwrap_or("").to_string();
    let identity_reading = aggregate.get("identified_by").map(Json::each).unwrap_or(&[]).iter().map(Json::to_s).collect::<Vec<_>>().join(", ");

    let attrs = command.get("attributes").map(Json::each).unwrap_or(&[]);
    let mut args_struct = vec![format!("pub struct {cmd}Args {{")];
    for attr in attrs {
        let mut ty = naming::rust_type(crate::attr::type_name(attr), crate::attr::list(attr));
        if crate::attr::optional(attr) {
            ty = format!("Option<{ty}>");
        }
        args_struct.push(format!("    {}", exemplar.render("struct_field", &[("TmplFieldType", ty), ("tmpl_field", naming::rust_ident_field(crate::attr::name(attr)))])));
    }
    args_struct.push("}".to_string());

    let invariant_checks = invariant_checks_for(exemplar, command, aggregates_by_name, value_objects_by_name);

    let givens = command.get("givens").map(Json::each).unwrap_or(&[]);
    let mut given_specs: Vec<String> = crate::bridging::corrects_given_specs(command);
    given_specs.extend(givens.iter().map(|g| {
        let description = g.get("description").and_then(Json::as_str).unwrap_or("");
        let ast = g.get("ast").unwrap_or_else(|| panic!("given row has no ast: {g:?}"));
        format!("            crate::kernel::GivenSpec {{ description: {}, expr: {}, corrects_event: None }},", naming::ruby_inspect_string(description), crate::expr_emitter::emit_ast(ast))
    }));

    let ensures = command.get("ensures").map(Json::each).unwrap_or(&[]);
    let ensures_specs: Vec<String> = ensures
        .iter()
        .map(|e| {
            let description = e.get("description").and_then(Json::as_str).unwrap_or("");
            let ast = e.get("ast").unwrap_or_else(|| panic!("ensures row has no ast: {e:?}"));
            format!("            crate::kernel::EnsuresSpec {{ description: {}, expr: {} }},", naming::ruby_inspect_string(description), crate::expr_emitter::emit_ast(ast))
        })
        .collect();

    let transition = mutations::lifecycle_transition_for(command, aggregate);
    let transition_arg = match &transition {
        Some(t) => format!(
            "Some(crate::kernel::TransitionCheck {{ field: {}, from_states: &[{}] }})",
            naming::ruby_inspect_string(&t.field),
            t.from_states.iter().map(|s| naming::ruby_inspect_string(s)).collect::<Vec<_>>().join(", ")
        ),
        None => "None".to_string(),
    };

    let mutations_list = command.get("mutations").map(Json::each).unwrap_or(&[]);
    // A `delegate` mutation is rendered by `delegation_of`, which overwrites `mutation_lines`;
    // `mutations::emit_mutation_line` panics on the op, so it must be excluded here.
    let mut mutation_lines: Vec<String> = mutations_list
        .iter()
        .filter(|m| {
            let op = m.get("op").map(Json::to_s).unwrap_or_default();
            op != "corrects" && op != "delegate"
        })
        .map(|m| mutations::emit_mutation_line(exemplar, m, aggregate, command, value_objects_by_name, true))
        .collect();
    if mutations::reads_pre_state(mutations_list) {
        mutation_lines.insert(0, mutations::pre_state_line());
    }
    // Stamp the fact forward for every command whose `emits` names an event a `corrects` targets.
    let correctable = crate::bridging::correctable_event_names(aggregate);
    let mut emitted_names: Vec<String> = Vec::new();
    for name in command.get("emits").map(Json::each).unwrap_or(&[]).iter().map(Json::to_s) {
        // `.uniq`: first-occurrence order, not sorted.
        if !emitted_names.contains(&name) {
            emitted_names.push(name);
        }
    }
    for name in &emitted_names {
        if correctable.contains(name) {
            mutation_lines.push(format!("        record.{} = true;", crate::bridging::corrects_flag_field(name)));
        }
    }
    if let Some(t) = &transition {
        if !t.to_state.is_empty() {
            mutation_lines.push(format!("        record.{} = {}.to_string();", naming::rust_ident_field(&t.field), naming::ruby_inspect_string(&t.to_state)));
        }
    }
    if mutation_lines.is_empty() {
        mutation_lines = vec!["        let _ = record;".to_string()];
    }
    let delegation = delegation_of(exemplar, command, aggregate, value_objects_by_name, domain_name);
    if let Some(d) = &delegation {
        assert!(!creates, "{cmd}: a creating command cannot delegate — nothing exists to delegate to");
        // `d.element` runs first, inside the closure `dispatch` calls after a successful hydrate.
        mutation_lines = vec![d.element.clone(), d.apply.clone()];
    }
    let prelude = delegation.as_ref().map(|d| d.prelude.clone()).unwrap_or_default();
    let payload = if delegation.is_some() { "delegate_facts.clone()," } else { "args.to_json()," }.to_string();

    let (hydrate, fn_signature);
    // A `projects` field is never a command argument; `seed_projections` populates it before save.
    // Owned because the pseudo-attributes are freshly built.
    let mut record_agg_attrs_owned: Vec<Json> = aggregate.get("attributes").map(Json::each).unwrap_or(&[]).to_vec();
    record_agg_attrs_owned.extend(crate::types::projected_field_pseudo_attributes(aggregate));
    let record_agg_attrs = record_agg_attrs_owned.as_slice();

    if creates {
        let record_fields: Vec<String> = record_agg_attrs
            .iter()
            .map(|attr| {
                let matched = attrs.iter().find(|a| crate::attr::name(a) == crate::attr::name(attr));
                let field = naming::rust_ident_field(crate::attr::name(attr));
                if let Some(matched) = matched {
                    let matched_type = crate::attr::type_name(matched);
                    let attr_type = crate::attr::type_name(attr);
                    if crate::attr::optional(matched) {
                        if crate::attr::list(attr) && !crate::shared::list_attr_creation_optional(aggregate, crate::attr::name(attr), value_objects_by_name) {
                            format!("            {field}: args.{field}.clone().unwrap_or_default(),")
                        } else if crate::attr::list(attr) || matched_type == attr_type {
                            format!("            {field}: args.{field}.clone(),")
                        } else {
                            // A cross-aggregate argument named like the owner's field but of
                            // another type needs a bridge.
                            format!("            {field}: {},", mutations::optional_value_rhs(&format!("args.{field}"), matched_type, attr_type, value_objects_by_name))
                        }
                    } else if crate::attr::list(attr) || matched_type == attr_type {
                        if crate::attr::list(attr) {
                            format!("            {field}: args.{field}.clone(),")
                        } else {
                            format!("            {field}: Some(args.{field}.clone()),")
                        }
                    } else {
                        format!("            {field}: Some({}),", crate::bridging::value_rhs(&format!("args.{field}"), matched_type, attr_type, value_objects_by_name))
                    }
                } else if crate::attr::list(attr) {
                    format!("            {field}: vec![],")
                } else {
                    match crate::bridging::creation_default_rhs(attr, value_objects_by_name) {
                        Some(rhs) => format!("            {field}: Some({rhs}),"),
                        None => format!("            {field}: None,"),
                    }
                }
            })
            .collect();
        let mut record_fields = record_fields;
        if let Some(lifecycle) = aggregate.get("lifecycle") {
            let field = lifecycle.get("field").and_then(Json::as_str).unwrap_or("");
            let default = lifecycle.get("default").map(Json::to_s).unwrap_or_default();
            record_fields.push(format!("            {}: {}.to_string(),", naming::rust_ident_field(field), naming::ruby_inspect_string(&default)));
        }
        for ev in crate::bridging::correctable_event_names(aggregate) {
            record_fields.push(format!("            {}: false,", crate::bridging::corrects_flag_field(&ev)));
        }

        // Mirrors `CommandInterpreter#step_hydrate`: `complete_state? && state_independent?`.
        let state_independent = crate::dependency_planning::state_independent_creation(aggregate, command, value_objects_by_name);
        let create_block = format!(
            "crate::kernel::Hydrate::Create {{\n        id: __hydrate_id,\n        build: Box::new(|| {record} {{\n{}\n        }}),\n        state_independent: {state_independent},\n    }}",
            record_fields.join("\n")
        );

        // A route on a creating command is checked against its derived identity (`TypeMismatch`)
        // only when `complete_state_creation` holds; otherwise it forces find-or-`NotFound`.
        let complete_state = crate::dependency_planning::complete_state_creation(aggregate, command, value_objects_by_name);
        let derived_id_expr = mutations::build_identity_expr(&identity);
        let route_mismatch_message = format!(
            "{} routes to {{:?}}, but its identity facts name {{:?}}",
            command.get("name").and_then(Json::as_str).unwrap_or("")
        );
        let route_arm = if complete_state {
            format!(
                "Some(__route) => {{\n        __route.require_depth(0)?;\n        let __hydrate_id: String = {derived_id_expr};\n        if __route.aggregate() != __hydrate_id.as_str() {{\n            return Err(crate::kernel::Refusal::TypeMismatch(format!({}, __route.aggregate(), __hydrate_id)));\n        }}\n        {create_block}\n    }}",
                naming::ruby_inspect_string(&route_mismatch_message)
            )
        } else {
            "Some(__route) => {\n        __route.require_depth(0)?;\n        crate::kernel::Hydrate::Act { id: __route.aggregate().to_string() }\n    }".to_string()
        };
        hydrate = format!(
            "match route {{\n        {route_arm}\n        None => {{ let __hydrate_id: String = {derived_id_expr}; {create_block} }}\n    }}"
        );
        let mut sig_parts = vec![
            format!("repo: &mut impl crate::kernel::Repository<{record}>"),
            "route: Option<&crate::kernel::RoutingEnvelope>".to_string(),
        ];
        sig_parts.extend(identity_extra_params.iter().cloned());
        sig_parts.push(format!("args: {cmd}Args"));
        sig_parts.push("mutations: &mut Vec<crate::kernel::MutationRecord>".to_string());
        sig_parts.extend(deref_params().iter().map(|s| s.to_string()));
        sig_parts.push(TENANT_BOUNDARY_PARAM.to_string());
        fn_signature = sig_parts.join(", ");
    } else {
        let mut sig_parts = vec![
            format!("repo: &mut impl crate::kernel::Repository<{record}>"),
            "id: &str".to_string(),
            format!("args: {cmd}Args"),
            "mutations: &mut Vec<crate::kernel::MutationRecord>".to_string(),
        ];
        sig_parts.extend(deref_params().iter().map(|s| s.to_string()));
        sig_parts.push(TENANT_BOUNDARY_PARAM.to_string());
        hydrate = "crate::kernel::Hydrate::Act { id: id.to_string() }".to_string();
        fn_signature = sig_parts.join(", ");
    }

    let emits_expr = match &delegation {
        Some(d) => d.emits.iter().map(|e| naming::ruby_inspect_string(e)).collect::<Vec<_>>().join(", "),
        None => command.get("emits").map(Json::each).unwrap_or(&[]).iter().map(|e| naming::ruby_inspect_string(&e.to_s())).collect::<Vec<_>>().join(", "),
    };

    let dispatch_fn = exemplar.render(
        "dispatch_fn",
        &[
            (
                "repo: &mut impl crate::kernel::Repository<TmplRecord>, id: &str, args: TmplArgs, mutations: &mut Vec<crate::kernel::MutationRecord>, tenant_boundary_check: Result<(), crate::kernel::Refusal>",
                fn_signature,
            ),
            ("dispatch_tmpl", format!("dispatch_{}", naming::dispatch_fn_name(&cmd))),
            ("TmplRecord", record),
            ("tmpl_invariant_check_placeholder()?;", invariant_checks.join("\n")),
            ("let tmpl_eval_fielded = tmpl_with_references_placeholder();", with_references_binding()),
            ("&tmpl_eval_fielded,", "&with_references,".to_string()),
            ("let tmpl_seed_projections = tmpl_seed_projections_placeholder();", seed_projections_binding(aggregate)),
            ("tmpl_seed_projections,", "seed_projections,".to_string()),
            ("tmpl_hydrate_placeholder()", hydrate),
            ("tmpl_prelude_placeholder();", prelude),
            ("\"TmplCmdName\"", naming::ruby_inspect_string(&cmd)),
            ("\"TmplQualifiedName\"", naming::ruby_inspect_string(&format!("{domain_name}::{}", aggregate.get("name").and_then(Json::as_str).unwrap_or("")))),
            ("\"TmplAggregateName\"", naming::ruby_inspect_string(&aggregate_name)),
            ("\"TmplIdentityReading\"", naming::ruby_inspect_string(&identity_reading)),
            ("tmpl_given_spec_placeholder(),", given_specs.join("\n")),
            ("tmpl_transition_placeholder()", transition_arg),
            ("tmpl_mutation_lines_placeholder(record);", mutation_lines.join("\n")),
            ("tmpl_ensures_spec_placeholder(),", ensures_specs.join("\n")),
            ("tmpl_invariants_placeholder()", format!("{}()", invariants_fn_name(aggregate))),
            ("tmpl_emit_placeholder()", emits_expr),
            ("args.to_json(),", payload),
        ],
    );

    format!("{}\n\n#[derive(Debug, Clone)]\n{}\n\n{dispatch_fn}", crate::fielded::emit_fielded_flat(exemplar, &format!("{cmd}Args"), attrs, value_objects_by_name, &[]), args_struct.join("\n"))
}

/// The `:delegate` mutation (`delegates_to`).
fn delegate_of(command: &Json) -> Option<&Json> {
    command.get("mutations").map(Json::each).unwrap_or(&[]).iter().find(|m| m.get("op").map(Json::to_s).unwrap_or_default() == "delegate")
}

fn delegate_mapping(delegation: &Json) -> Vec<(String, String)> {
    match delegation.get("fields") {
        Some(Json::Object(pairs)) => pairs.iter().map(|(k, v)| (k.clone(), v.to_s().trim_start_matches(':').to_string())).collect(),
        _ => Vec::new(),
    }
}

fn delegate_target<'a>(delegation: &Json, aggregate: &'a Json) -> (Option<&'a Json>, Option<&'a Json>) {
    let target = delegation.get("target").map(Json::to_s).unwrap_or_default();
    let (entity_name, command_name) = match target.rfind('.') {
        Some(dot) => (&target[..dot], &target[dot + 1..]),
        None => ("", target.as_str()),
    };
    let entity = aggregate.get("entities").map(Json::each).unwrap_or(&[]).iter().find(|e| e.get("name").map(Json::to_s).unwrap_or_default() == entity_name);
    let command = entity.and_then(|e| e.get("commands").map(Json::each).unwrap_or(&[]).iter().find(|c| c.get("name").map(Json::to_s).unwrap_or_default() == command_name));
    (entity, command)
}

pub fn delegate_skip_reason(command: &Json, aggregate: &Json, value_objects_by_name: &HashMap<String, &Json>) -> Option<String> {
    let delegation = delegate_of(command)?;
    let label = format!("delegates_to {}", delegation.get("target").map(Json::to_s).unwrap_or_default());
    if command.get("mutations").map(Json::each).unwrap_or(&[]).len() > 1 {
        return Some(format!("{label} alongside other sets — not generated yet"));
    }
    let (entity, target) = delegate_target(delegation, aggregate);
    let Some(entity) = entity else {
        return Some(format!("{label}: {} has no such entity", aggregate.get("name").map(Json::to_s).unwrap_or_default()));
    };
    let entity_name = entity.get("name").map(Json::to_s).unwrap_or_default();
    let Some(target) = target else {
        return Some(format!("{label}: {entity_name} declares no such command"));
    };
    if !crate::json_codec::extract_id_supported(entity) {
        return Some(format!("{label}: {entity_name} cannot be addressed by identity"));
    }
    if let Some(problem) = entity_command_skip_reason(target, entity, value_objects_by_name) {
        return Some(format!("{label}: {problem}"));
    }
    let mapping = delegate_mapping(delegation);
    let source_name_for = |name: &str| mapping.iter().find(|(t, _)| t == name).map(|(_, s)| s.clone()).unwrap_or_else(|| name.to_string());
    let door_attrs = command.get("attributes").map(Json::each).unwrap_or(&[]);
    for attr in target.get("attributes").map(Json::each).unwrap_or(&[]) {
        let name = crate::attr::name(attr);
        let source_name = source_name_for(name);
        let source = door_attrs.iter().find(|a| crate::attr::name(a) == source_name);
        let Some(source) = source else {
            if crate::attr::optional(attr) {
                continue;
            }
            return Some(format!("{label}: target argument {name} has no source on the door"));
        };
        if crate::attr::list(source) != crate::attr::list(attr) {
            return Some(format!("{label}: door argument {source_name} is a list, target wants a scalar (or vice versa) — not generated yet"));
        }
        // Bridgeable, not exact type-name equality: the alias-then-deserialize delegate never
        // compares declared type names (docs/decisions/0045).
        if !crate::bridging::bridgeable_value_types(crate::attr::type_name(source), crate::attr::type_name(attr), value_objects_by_name) {
            return Some(format!("{label}: door argument {source_name} is {}, target wants {} — not generated yet", crate::attr::type_name(source), crate::attr::type_name(attr)));
        }
        if crate::attr::optional(source) && !crate::attr::optional(attr) {
            return Some(format!("{label}: optional door argument {source_name} feeds required {name}"));
        }
    }
    for path in entity.get("identified_by").map(Json::each).unwrap_or(&[]) {
        let path = path.to_s();
        let head = path.split('.').next().unwrap_or("").to_string();
        let source_name = source_name_for(&head);
        if door_attrs.iter().any(|a| crate::attr::name(a) == source_name && !crate::attr::optional(a)) {
            continue;
        }
        return Some(format!("{label}: the element's identity {head} has no source on the door"));
    }
    None
}

struct Delegation {
    prelude: String,
    // Split from `prelude` so the element identity is extracted after `dispatch`'s hydrate.
    element: String,
    apply: String,
    emits: Vec<String>,
}

fn indent_block(text: &str, indent: &str) -> String {
    text.lines().map(|l| format!("{indent}{l}")).collect::<Vec<_>>().join("\n").trim_end().to_string()
}

fn delegation_of(exemplar: &Exemplar, command: &Json, aggregate: &Json, value_objects_by_name: &HashMap<String, &Json>, domain_name: &str) -> Option<Delegation> {
    let delegation = delegate_of(command)?;
    let (entity, target) = delegate_target(delegation, aggregate);
    let (entity, target) = (entity.expect("delegate_skip_reason admitted the entity"), target.expect("delegate_skip_reason admitted the target"));
    let entity_name = entity.get("name").map(Json::to_s).unwrap_or_default();
    let aggregate_name = aggregate.get("name").map(Json::to_s).unwrap_or_default();
    let list_attr = aggregate
        .get("attributes")
        .map(Json::each)
        .unwrap_or(&[])
        .iter()
        .find(|a| crate::attr::list(a) && crate::attr::type_name(a) == entity_name)
        .unwrap_or_else(|| panic!("{entity_name}: no list attribute on {aggregate_name} holds it"));

    let element_record = naming::rust_ident(&entity_name);
    let target_args_name = format!("{element_record}{}EntityArgs", naming::rust_ident(&target.get("name").map(Json::to_s).unwrap_or_default()));
    let aliases: Vec<String> = delegate_mapping(delegation).iter().map(|(t, s)| format!("({}, {})", naming::ruby_inspect_string(t), naming::ruby_inspect_string(s))).collect();
    let given_specs: Vec<String> = target
        .get("givens")
        .map(Json::each)
        .unwrap_or(&[])
        .iter()
        .map(|g| {
            let description = g.get("description").and_then(Json::as_str).unwrap_or("");
            let ast = g.get("ast").unwrap_or_else(|| panic!("given row has no ast: {g:?}"));
            format!("            crate::kernel::GivenSpec {{ description: {}, expr: {}, corrects_event: None }},", naming::ruby_inspect_string(description), crate::expr_emitter::emit_ast(ast))
        })
        .collect();
    let ensures_specs: Vec<String> = target
        .get("ensures")
        .map(Json::each)
        .unwrap_or(&[])
        .iter()
        .map(|e| {
            let description = e.get("description").and_then(Json::as_str).unwrap_or("");
            let ast = e.get("ast").unwrap_or_else(|| panic!("ensures row has no ast: {e:?}"));
            format!("            crate::kernel::EnsuresSpec {{ description: {}, expr: {} }},", naming::ruby_inspect_string(description), crate::expr_emitter::emit_ast(ast))
        })
        .collect();
    let transition = mutations::lifecycle_transition_for(target, entity);
    let transition_arg = match &transition {
        Some(t) => format!(
            "Some(crate::kernel::TransitionCheck {{ field: {}, from_states: &[{}] }})",
            naming::ruby_inspect_string(&t.field),
            t.from_states.iter().map(|s| naming::ruby_inspect_string(s)).collect::<Vec<_>>().join(", ")
        ),
        None => "None".to_string(),
    };
    let mut mutation_lines: Vec<String> = target
        .get("mutations")
        .map(Json::each)
        .unwrap_or(&[])
        .iter()
        .map(|m| mutations::emit_mutation_line(exemplar, m, entity, target, value_objects_by_name, false))
        .collect();
    if mutations::reads_pre_state(target.get("mutations").map(Json::each).unwrap_or(&[])) {
        mutation_lines.insert(0, mutations::pre_state_line());
    }
    if let Some(t) = &transition {
        if !t.to_state.is_empty() {
            mutation_lines.push(format!("        record.{} = {}.to_string();", naming::rust_ident_field(&t.field), naming::ruby_inspect_string(&t.to_state)));
        }
    }
    if mutation_lines.is_empty() {
        mutation_lines = vec!["        let _ = record;".to_string()];
    }
    let identity_reading = entity.get("identified_by").map(Json::each).unwrap_or(&[]).iter().map(Json::to_s).collect::<Vec<_>>().join(", ");

    let prelude = exemplar.render("delegate_prelude", &[("tmpl_aliases_placeholder()", aliases.join(", ")), ("TmplTargetArgs", target_args_name)]);
    let element = exemplar.render("delegate_element", &[("TmplElement", element_record.clone())]);
    let apply = exemplar.render(
        "delegate_apply",
        &[
            ("TmplRecord", naming::rust_ident(&aggregate_name)),
            ("tmpl_list_field", naming::rust_ident_field(crate::attr::name(list_attr))),
            ("TmplElement", element_record),
            // Bare, not entity-qualified: it feeds refusal-message text, as in Ruby.
            ("\"TmplQualifiedCommandName\"", naming::ruby_inspect_string(&target.get("name").map(Json::to_s).unwrap_or_default())),
            // Lets `apply_entity_command` (kernel/dispatch.rs) judge `corrects` admissibility.
            ("\"TmplQualifiedName\"", naming::ruby_inspect_string(&format!("{domain_name}::{aggregate_name}"))),
            ("\"TmplAggregateName\"", naming::ruby_inspect_string(&aggregate_name)),
            ("\"TmplEntityName\"", naming::ruby_inspect_string(&entity_name)),
            ("\"TmplEntityIdentityReading\"", naming::ruby_inspect_string(&identity_reading)),
            ("tmpl_given_spec_placeholder(),", given_specs.join("\n")),
            ("tmpl_transition_placeholder()", transition_arg),
            ("tmpl_entity_mutation_lines_placeholder(record);", mutation_lines.join("\n")),
            ("tmpl_ensures_spec_placeholder(),", ensures_specs.join("\n")),
        ],
    );
    Some(Delegation {
        prelude: indent_block(&prelude, "    "),
        element: indent_block(&element, "        "),
        apply: indent_block(&apply, "        "),
        emits: target.get("emits").map(Json::each).unwrap_or(&[]).iter().map(Json::to_s).collect(),
    })
}

/// `command_skip_reason` for an entity command; an entity has the same IR shape as an aggregate.
pub fn entity_command_skip_reason(command: &Json, entity: &Json, value_objects_by_name: &HashMap<String, &Json>) -> Option<SkipReason> {
    command_skip_reason_with(command, entity, value_objects_by_name, false)
}

/// Emits the dispatch function for an entity command.
pub fn emit_entity_command(
    exemplar: &Exemplar,
    command: &Json,
    entity: &Json,
    parent_aggregate: &Json,
    domain_name: &str,
    value_objects_by_name: &HashMap<String, &Json>,
    aggregates_by_name: &HashMap<String, &Json>,
    process_managers: &[Json],
) -> String {
    let parent_record = naming::rust_ident(parent_aggregate.get("name").and_then(Json::as_str).unwrap_or(""));
    let element_record = naming::rust_ident(entity.get("name").and_then(Json::as_str).unwrap_or(""));
    let cmd = naming::rust_ident(command.get("name").and_then(Json::as_str).unwrap_or(""));

    let aggregate_name = parent_aggregate.get("name").and_then(Json::as_str).unwrap_or("").to_string();
    let parent_identity_reading = parent_aggregate.get("identified_by").map(Json::each).unwrap_or(&[]).iter().map(Json::to_s).collect::<Vec<_>>().join(", ");
    let entity_name = entity.get("name").and_then(Json::as_str).unwrap_or("").to_string();
    let entity_identity_reading = entity.get("identified_by").map(Json::each).unwrap_or(&[]).iter().map(Json::to_s).collect::<Vec<_>>().join(", ");

    let parent_attrs = parent_aggregate.get("attributes").map(Json::each).unwrap_or(&[]);
    let list_attr = parent_attrs
        .iter()
        .find(|a| crate::attr::list(a) && crate::attr::type_name(a) == entity.get("name").and_then(Json::as_str).unwrap_or(""))
        .unwrap_or_else(|| panic!("{entity_name}: no list attribute on {aggregate_name} holds it — unsupported_attribute_types should have caught this"));
    let list_field = naming::rust_ident_field(crate::attr::name(list_attr));
    let args_struct_name = format!("{element_record}{cmd}EntityArgs");

    let attrs = command.get("attributes").map(Json::each).unwrap_or(&[]);
    let mut args_struct = vec![format!("pub struct {args_struct_name} {{")];
    for attr in attrs {
        let mut ty = naming::rust_type(crate::attr::type_name(attr), crate::attr::list(attr));
        if crate::attr::optional(attr) {
            ty = format!("Option<{ty}>");
        }
        args_struct.push(format!("    {}", exemplar.render("struct_field", &[("TmplFieldType", ty), ("tmpl_field", naming::rust_ident_field(crate::attr::name(attr)))])));
    }
    args_struct.push("}".to_string());

    let invariant_checks = invariant_checks_for(exemplar, command, aggregates_by_name, value_objects_by_name);

    // `corrects_given_specs` is prepended as in `emit_command`; `apply_entity_command` evaluates
    // it against the parent record, never the entity's element.
    let givens = command.get("givens").map(Json::each).unwrap_or(&[]);
    let mut given_specs: Vec<String> = crate::bridging::corrects_given_specs(command);
    given_specs.extend(givens.iter().map(|g| {
        let description = g.get("description").and_then(Json::as_str).unwrap_or("");
        let ast = g.get("ast").unwrap_or_else(|| panic!("given row has no ast: {g:?}"));
        format!("            crate::kernel::GivenSpec {{ description: {}, expr: {}, corrects_event: None }},", naming::ruby_inspect_string(description), crate::expr_emitter::emit_ast(ast))
    }));

    let ensures = command.get("ensures").map(Json::each).unwrap_or(&[]);
    let ensures_specs: Vec<String> = ensures
        .iter()
        .map(|e| {
            let description = e.get("description").and_then(Json::as_str).unwrap_or("");
            let ast = e.get("ast").unwrap_or_else(|| panic!("ensures row has no ast: {e:?}"));
            format!("            crate::kernel::EnsuresSpec {{ description: {}, expr: {} }},", naming::ruby_inspect_string(description), crate::expr_emitter::emit_ast(ast))
        })
        .collect();

    let transition = mutations::lifecycle_transition_for(command, entity);
    let transition_arg = match &transition {
        Some(t) => format!(
            "Some(crate::kernel::TransitionCheck {{ field: {}, from_states: &[{}] }})",
            naming::ruby_inspect_string(&t.field),
            t.from_states.iter().map(|s| naming::ruby_inspect_string(s)).collect::<Vec<_>>().join(", ")
        ),
        None => "None".to_string(),
    };

    let mutations_list = command.get("mutations").map(Json::each).unwrap_or(&[]);
    let mut mutation_lines: Vec<String> = mutations_list.iter().map(|m| mutations::emit_mutation_line(exemplar, m, entity, command, value_objects_by_name, false)).collect();
    if mutations::reads_pre_state(mutations_list) {
        mutation_lines.insert(0, mutations::pre_state_line());
    }
    if let Some(t) = &transition {
        if !t.to_state.is_empty() {
            mutation_lines.push(format!("        record.{} = {}.to_string();", naming::rust_ident_field(&t.field), naming::ruby_inspect_string(&t.to_state)));
        }
    }
    if mutation_lines.is_empty() {
        mutation_lines = vec!["        let _ = record;".to_string()];
    }

    // Bare, not entity-qualified, as in `delegate_apply`.
    let qualified_command_name = command.get("name").and_then(Json::as_str).unwrap_or("").to_string();
    let emits = command.get("emits").map(Json::each).unwrap_or(&[]);
    let emits_expr = emits.iter().map(|e| naming::ruby_inspect_string(&e.to_s())).collect::<Vec<_>>().join(", ");

    let entity_dispatch_fn = exemplar.render(
        "entity_dispatch_fn",
        &[
            ("dispatch_entity_tmpl", format!("dispatch_entity_{}_{}", entity.get("name").and_then(Json::as_str).unwrap_or("").to_lowercase(), naming::dispatch_fn_name(&cmd))),
            ("TmplRecord", parent_record),
            ("TmplArgs", args_struct_name.clone()),
            ("tmpl_deref_params_placeholder: ()", deref_params().join(", ")),
            ("tmpl_invariant_check_placeholder()?;", invariant_checks.join("\n")),
            ("let tmpl_eval_fielded = tmpl_with_references_placeholder();", with_references_binding()),
            ("&tmpl_eval_fielded,", "&with_references,".to_string()),
            ("let tmpl_seed_projections = tmpl_seed_projections_placeholder();", seed_projections_binding(parent_aggregate)),
            ("tmpl_seed_projections,", "seed_projections,".to_string()),
            ("tmpl_list_field", list_field),
            ("TmplElement", element_record),
            ("\"TmplQualifiedCommandName\"", naming::ruby_inspect_string(&qualified_command_name)),
            ("\"TmplQualifiedName\"", naming::ruby_inspect_string(&format!("{domain_name}::{aggregate_name}"))),
            ("\"TmplAggregateName\"", naming::ruby_inspect_string(&aggregate_name)),
            ("\"TmplParentIdentityReading\"", naming::ruby_inspect_string(&parent_identity_reading)),
            ("\"TmplEntityName\"", naming::ruby_inspect_string(&entity_name)),
            ("\"TmplEntityIdentityReading\"", naming::ruby_inspect_string(&entity_identity_reading)),
            ("tmpl_given_spec_placeholder(),", given_specs.join("\n")),
            ("tmpl_transition_placeholder()", transition_arg),
            ("tmpl_entity_mutation_lines_placeholder(record);", mutation_lines.join("\n")),
            ("tmpl_ensures_spec_placeholder(),", ensures_specs.join("\n")),
            ("tmpl_invariants_placeholder()", format!("{}()", invariants_fn_name(parent_aggregate))),
            ("tmpl_emit_placeholder()", emits_expr),
        ],
    );

    [
        crate::fielded::emit_fielded_flat(exemplar, &args_struct_name, attrs, value_objects_by_name, &[]),
        format!("#[derive(Debug, Clone)]\n{}", args_struct.join("\n")),
        crate::json_codec::emit_to_json_flat_sparse(exemplar, &args_struct_name, attrs, value_objects_by_name),
        {
            // `unknown_argument_allowlist:` as for an aggregate command, plus the entity's
            // identity head (`extra_identity_heads:` in Ruby's `ArgumentGate`).
            let entity_identity_heads: Vec<String> = entity
                .get("identified_by")
                .map(Json::each)
                .unwrap_or(&[])
                .iter()
                .map(|p| p.to_s().split('.').next().unwrap_or("").to_string())
                .collect();
            let allowlist = crate::json_codec::command_argument_allowlist(parent_aggregate, command, process_managers, &entity_identity_heads);
            crate::json_codec::emit_from_json_flat(exemplar, &args_struct_name, attrs, value_objects_by_name, Some(&allowlist), Some(&qualified_command_name), true, true, Some(aggregates_by_name))
        },
        // Argument gates, run by `kernel::decode_entity_arguments` in `EntityStep::ORDER`.
        {
            let entity_identity_heads: Vec<String> = entity
                .get("identified_by")
                .map(Json::each)
                .unwrap_or(&[])
                .iter()
                .map(|p| p.to_s().split('.').next().unwrap_or("").to_string())
                .collect();
            let allowlist = crate::json_codec::command_argument_allowlist(parent_aggregate, command, process_managers, &entity_identity_heads);
            crate::json_codec::emit_argument_gates(&args_struct_name, &qualified_command_name, attrs, Some(&allowlist))
        },
        entity_dispatch_fn,
    ]
    .join("\n\n")
}

/// Emits the dispatch function for a command on an entity nested two levels deep.
/// Takes plain `&str` ids per hop, so routed and flat-args callers can both use it.
pub fn emit_nested_entity_command(
    exemplar: &Exemplar,
    command: &Json,
    nested: &Json,
    entity: &Json,
    parent_aggregate: &Json,
    domain_name: &str,
    value_objects_by_name: &HashMap<String, &Json>,
    aggregates_by_name: &HashMap<String, &Json>,
    process_managers: &[Json],
) -> String {
    let parent_record = naming::rust_ident(parent_aggregate.get("name").and_then(Json::as_str).unwrap_or(""));
    let entity_record = naming::rust_ident(entity.get("name").and_then(Json::as_str).unwrap_or(""));
    let nested_record = naming::rust_ident(nested.get("name").and_then(Json::as_str).unwrap_or(""));
    let cmd = naming::rust_ident(command.get("name").and_then(Json::as_str).unwrap_or(""));

    let aggregate_name = parent_aggregate.get("name").and_then(Json::as_str).unwrap_or("").to_string();
    let parent_identity_reading = parent_aggregate.get("identified_by").map(Json::each).unwrap_or(&[]).iter().map(Json::to_s).collect::<Vec<_>>().join(", ");
    let entity_name = entity.get("name").and_then(Json::as_str).unwrap_or("").to_string();
    let entity_identity_reading = entity.get("identified_by").map(Json::each).unwrap_or(&[]).iter().map(Json::to_s).collect::<Vec<_>>().join(", ");
    let nested_name = nested.get("name").and_then(Json::as_str).unwrap_or("").to_string();
    let nested_identity_reading = nested.get("identified_by").map(Json::each).unwrap_or(&[]).iter().map(Json::to_s).collect::<Vec<_>>().join(", ");

    let parent_attrs = parent_aggregate.get("attributes").map(Json::each).unwrap_or(&[]);
    let list_attr1 = parent_attrs
        .iter()
        .find(|a| crate::attr::list(a) && crate::attr::type_name(a) == entity.get("name").and_then(Json::as_str).unwrap_or(""))
        .unwrap_or_else(|| panic!("{entity_name}: no list attribute on {aggregate_name} holds it — unsupported_attribute_types should have caught this"));
    let list_field1 = naming::rust_ident_field(crate::attr::name(list_attr1));

    let entity_attrs = entity.get("attributes").map(Json::each).unwrap_or(&[]);
    let list_attr2 = entity_attrs
        .iter()
        .find(|a| crate::attr::list(a) && crate::attr::type_name(a) == nested.get("name").and_then(Json::as_str).unwrap_or(""))
        .unwrap_or_else(|| panic!("{nested_name}: no list attribute on {entity_name} holds it — unsupported_attribute_types should have caught this"));
    let list_field2 = naming::rust_ident_field(crate::attr::name(list_attr2));

    let args_struct_name = format!("{nested_record}{cmd}NestedEntityArgs");

    let attrs = command.get("attributes").map(Json::each).unwrap_or(&[]);
    let mut args_struct = vec![format!("pub struct {args_struct_name} {{")];
    for attr in attrs {
        let mut ty = naming::rust_type(crate::attr::type_name(attr), crate::attr::list(attr));
        if crate::attr::optional(attr) {
            ty = format!("Option<{ty}>");
        }
        args_struct.push(format!("    {}", exemplar.render("struct_field", &[("TmplFieldType", ty), ("tmpl_field", naming::rust_ident_field(crate::attr::name(attr)))])));
    }
    args_struct.push("}".to_string());

    let invariant_checks = invariant_checks_for(exemplar, command, aggregates_by_name, value_objects_by_name);

    let givens = command.get("givens").map(Json::each).unwrap_or(&[]);
    let given_specs: Vec<String> = givens
        .iter()
        .map(|g| {
            let description = g.get("description").and_then(Json::as_str).unwrap_or("");
            let ast = g.get("ast").unwrap_or_else(|| panic!("given row has no ast: {g:?}"));
            format!("                    crate::kernel::GivenSpec {{ description: {}, expr: {}, corrects_event: None }},", naming::ruby_inspect_string(description), crate::expr_emitter::emit_ast(ast))
        })
        .collect();

    let ensures = command.get("ensures").map(Json::each).unwrap_or(&[]);
    let ensures_specs: Vec<String> = ensures
        .iter()
        .map(|e| {
            let description = e.get("description").and_then(Json::as_str).unwrap_or("");
            let ast = e.get("ast").unwrap_or_else(|| panic!("ensures row has no ast: {e:?}"));
            format!("                    crate::kernel::EnsuresSpec {{ description: {}, expr: {} }},", naming::ruby_inspect_string(description), crate::expr_emitter::emit_ast(ast))
        })
        .collect();

    // The nested entity's lifecycle, as in `emit_entity_command`.
    let transition = mutations::lifecycle_transition_for(command, nested);
    let transition_arg = match &transition {
        Some(t) => format!(
            "Some(crate::kernel::TransitionCheck {{ field: {}, from_states: &[{}] }})",
            naming::ruby_inspect_string(&t.field),
            t.from_states.iter().map(|s| naming::ruby_inspect_string(s)).collect::<Vec<_>>().join(", ")
        ),
        None => "None".to_string(),
    };

    let mutations_list = command.get("mutations").map(Json::each).unwrap_or(&[]);
    let mut mutation_lines: Vec<String> = mutations_list.iter().map(|m| mutations::emit_mutation_line(exemplar, m, nested, command, value_objects_by_name, false)).collect();
    if mutations::reads_pre_state(mutations_list) {
        mutation_lines.insert(0, mutations::pre_state_line());
    }
    if let Some(t) = &transition {
        if !t.to_state.is_empty() {
            mutation_lines.push(format!("                record.{} = {}.to_string();", naming::rust_ident_field(&t.field), naming::ruby_inspect_string(&t.to_state)));
        }
    }
    if mutation_lines.is_empty() {
        mutation_lines = vec!["                let _ = record;".to_string()];
    }

    // Bare, as in `emit_entity_command`.
    let qualified_command_name = command.get("name").and_then(Json::as_str).unwrap_or("").to_string();
    // The hop-2 `apply_entity_command` gets the root aggregate's qualified name only to satisfy
    // the signature: its `record` is the hop-1 entity, so `corrects` admissibility is not checked
    // there. Its trailing `parent_in_args` literal is `true`, byte for byte as Ruby emits.
    let emits = command.get("emits").map(Json::each).unwrap_or(&[]);
    let emits_expr = emits.iter().map(|e| naming::ruby_inspect_string(&e.to_s())).collect::<Vec<_>>().join(", ");
    let fn_name = format!(
        "dispatch_entity_{}_{}_{}",
        entity.get("name").and_then(Json::as_str).unwrap_or("").to_lowercase(),
        nested.get("name").and_then(Json::as_str).unwrap_or("").to_lowercase(),
        naming::dispatch_fn_name(&cmd)
    );

    let nested_dispatch_fn = format!(
        "pub fn {fn_name}(\n    \
            repo: &mut impl crate::kernel::Repository<{parent_record}>, parent_id: &str, hop1_id: &str, hop1_wants: &str,\n    \
            hop2_id: &str, hop2_wants: &str, args: {args_struct_name}, mutations: &mut Vec<crate::kernel::MutationRecord>,\n    \
            owner_deref: Vec<(&'static str, crate::kernel::DerefNode)>, command_deref: Vec<(&'static str, crate::kernel::DerefNode)>,\n\
        ) -> crate::kernel::DispatchResult<{parent_record}> {{\n\
        {invariant_checks}\n    \
            {with_references}\n    \
            {seed_projections}\n\n    \
            crate::kernel::dispatch_entity(\n        \
                repo,\n        \
                parent_id,\n        \
                |r: &{parent_record}| &r.{list_field1},\n        \
                |r: &mut {parent_record}| &mut r.{list_field1},\n        \
                |el: &{entity_record}| el.identity() == hop1_id,\n        \
                {qualified_command_name_inspect},\n        \
                {qualified_name_inspect},\n        \
                {aggregate_name_inspect},\n        \
                {parent_identity_reading_inspect},\n        \
                {entity_name_inspect},\n        \
                {entity_identity_reading_inspect},\n        \
                hop1_wants,\n        \
                &with_references,\n        \
                &[],\n        \
                None,\n        \
                |nested_owner: &mut {entity_record}| {{\n            \
                    crate::kernel::apply_entity_command(\n                \
                        nested_owner,\n                \
                        hop1_id,\n                \
                        |r: &{entity_record}| &r.{list_field2},\n                \
                        |r: &mut {entity_record}| &mut r.{list_field2},\n                \
                        |el: &{nested_record}| el.identity() == hop2_id,\n                \
                        {qualified_command_name_inspect},\n                \
                        {qualified_name_inspect},\n                \
                        {aggregate_name_inspect},\n                \
                        {nested_name_inspect},\n                \
                        {nested_identity_reading_inspect},\n                \
                        hop2_wants,\n                \
                        &with_references,\n                \
                        &[\n{given_specs}\n                \
                        ],\n                \
                        {transition_arg},\n                \
                        |record| {{\n{mutation_lines}\n                    \
                            Ok(())\n                \
                        }},\n                \
                        &[\n{ensures_specs}\n                \
                        ],\n                \
                        true,\n            \
                    )\n        \
                }},\n        \
                &[],\n        \
                &{invariants_fn}(),\n        \
                &[{emits_expr}],\n        \
                args.to_json(),\n        \
                mutations,\n        \
                seed_projections,\n    \
            )\n\
        }}\n",
        invariant_checks = invariant_checks.join("\n"),
        with_references = with_references_binding(),
        seed_projections = seed_projections_binding(parent_aggregate),
        qualified_command_name_inspect = naming::ruby_inspect_string(&qualified_command_name),
        qualified_name_inspect = naming::ruby_inspect_string(&format!("{domain_name}::{aggregate_name}")),
        aggregate_name_inspect = naming::ruby_inspect_string(&aggregate_name),
        parent_identity_reading_inspect = naming::ruby_inspect_string(&parent_identity_reading),
        entity_name_inspect = naming::ruby_inspect_string(&entity_name),
        entity_identity_reading_inspect = naming::ruby_inspect_string(&entity_identity_reading),
        nested_name_inspect = naming::ruby_inspect_string(&nested_name),
        nested_identity_reading_inspect = naming::ruby_inspect_string(&nested_identity_reading),
        given_specs = given_specs.join("\n"),
        ensures_specs = ensures_specs.join("\n"),
        mutation_lines = mutation_lines.join("\n"),
        invariants_fn = invariants_fn_name(parent_aggregate),
        emits_expr = emits_expr,
    );

    [
        crate::fielded::emit_fielded_flat(exemplar, &args_struct_name, attrs, value_objects_by_name, &[]),
        format!("#[derive(Debug, Clone)]\n{}", args_struct.join("\n")),
        crate::json_codec::emit_to_json_flat_sparse(exemplar, &args_struct_name, attrs, value_objects_by_name),
        {
            // Both hops' identity heads, as `ctx.chain.flat_map(&:identity_heads)` in Ruby.
            let mut identity_heads: Vec<String> = entity
                .get("identified_by")
                .map(Json::each)
                .unwrap_or(&[])
                .iter()
                .map(|p| p.to_s().split('.').next().unwrap_or("").to_string())
                .collect();
            identity_heads.extend(
                nested
                    .get("identified_by")
                    .map(Json::each)
                    .unwrap_or(&[])
                    .iter()
                    .map(|p| p.to_s().split('.').next().unwrap_or("").to_string()),
            );
            let allowlist = crate::json_codec::command_argument_allowlist(parent_aggregate, command, process_managers, &identity_heads);
            crate::json_codec::emit_from_json_flat(exemplar, &args_struct_name, attrs, value_objects_by_name, Some(&allowlist), Some(&qualified_command_name), true, true, Some(aggregates_by_name))
        },
        // Argument gates, as in the one-hop entity command.
        {
            let mut identity_heads: Vec<String> = entity
                .get("identified_by")
                .map(Json::each)
                .unwrap_or(&[])
                .iter()
                .map(|p| p.to_s().split('.').next().unwrap_or("").to_string())
                .collect();
            identity_heads.extend(
                nested
                    .get("identified_by")
                    .map(Json::each)
                    .unwrap_or(&[])
                    .iter()
                    .map(|p| p.to_s().split('.').next().unwrap_or("").to_string()),
            );
            let allowlist = crate::json_codec::command_argument_allowlist(parent_aggregate, command, process_managers, &identity_heads);
            crate::json_codec::emit_argument_gates(&args_struct_name, &qualified_command_name, attrs, Some(&allowlist))
        },
        nested_dispatch_fn,
    ]
    .join("\n\n")
}
