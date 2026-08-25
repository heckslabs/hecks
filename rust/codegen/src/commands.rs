//! Port of `rust/project/commands.rb` — read that file's own header
//! comments in full; this mirrors its algorithm directly, function for
//! function.

use crate::exemplar::Exemplar;
use crate::json::Json;
use crate::literal::Literal;
use crate::mutations;
use crate::naming;
use std::collections::HashMap;

/// Port of `rust/project/commands.rb::DEREF_PARAMS` — the two EXTRA
/// parameters every generated `dispatch_*`/`dispatch_entity_*` function
/// now takes, already resolved by the ROUTER (`registry.rs`'s own
/// `aggregate_arms`/`entity_arms`) into plain owned data
/// (`reference_lookup.rs`'s own header on why that has to happen there).
fn deref_params() -> [&'static str; 2] {
    ["owner_deref: Vec<(&'static str, crate::kernel::DerefNode)>", "command_deref: Vec<(&'static str, crate::kernel::DerefNode)>"]
}

/// Port of `rust/project/commands.rb#with_references_binding`.
fn with_references_binding() -> String {
    "let with_references = crate::kernel::WithReferences { command_deref: &command_deref, args: &args, owner_deref: &owner_deref };".to_string()
}

fn target_type_for<'a>(target: &str, aggregate: &'a Json, lifecycle_field: Option<&str>) -> Option<&'a str> {
    if lifecycle_field == Some(target) {
        return Some("String");
    }
    let attrs = aggregate.get("attributes").map(Json::each).unwrap_or(&[]);
    attrs.iter().find(|a| crate::attr::name(a) == target).map(crate::attr::type_name)
}

pub fn command_skip_reason(command: &Json, aggregate: &Json, value_objects_by_name: &HashMap<String, &Json>) -> Option<String> {
    let mutations_list = command.get("mutations").map(Json::each).unwrap_or(&[]);

    let mut unsupported_ops: Vec<String> = Vec::new();
    for m in mutations_list {
        let op = m.get("op").map(Json::to_s).unwrap_or_default();
        if !["append", "set", "increment", "decrement", "delegate"].contains(&op.as_str()) && !unsupported_ops.contains(&op) {
            unsupported_ops.push(op);
        }
    }
    if !unsupported_ops.is_empty() {
        return Some(format!("sets op(s) {} not generated yet (only append/set/increment/decrement/delegate are)", unsupported_ops.join(", ")));
    }

    if let Some(problem) = delegate_skip_reason(command, aggregate, value_objects_by_name) {
        return Some(problem);
    }

    let append_problems = mutations::append_field_problems(command, aggregate, value_objects_by_name);
    if !append_problems.is_empty() {
        return Some(format!("sets append field(s): {}", append_problems.join("; ")));
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
        return Some(format!("sets to: a literal that doesn't bridge to the target's type ({}) — not generated yet", literal_set_targets.join(", ")));
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
            let source_type = cmd_attrs.iter().find(|a| crate::attr::name(a) == source_name).map(crate::attr::type_name);
            match (target_type, source_type) {
                (Some(t), Some(s)) => !crate::bridging::bridgeable_value_types(s, t, value_objects_by_name),
                _ => false,
            }
        })
        .map(|m| m.get("target").map(Json::to_s).unwrap_or_default())
        .collect();
    if !mismatched_sets.is_empty() {
        return Some(format!("sets :{} sources an argument no single-field rewrap can bridge to the target's type — not generated yet", mismatched_sets.join(", ")));
    }

    let arithmetic_targets: Vec<&Json> = mutations_list.iter().filter(|m| ["increment", "decrement"].contains(&m.get("op").map(Json::to_s).unwrap_or_default().as_str())).collect();
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
        return Some(format!("sets :{} increment/decrement amount or target field isn't bridgeable — not generated yet", unsupported_arithmetic.join(", ")));
    }

    let optional_problems = optional_source_mismatches(command, aggregate, value_objects_by_name);
    if !optional_problems.is_empty() {
        return Some(format!("optional argument feeds a non-optional target: {} — not generated yet", optional_problems.join("; ")));
    }

    let constraint_problems = constraint_list_problems(command);
    if !constraint_problems.is_empty() {
        return Some(constraint_problems.join("; "));
    }

    None
}

pub fn optional_source_mismatches(command: &Json, aggregate: &Json, value_objects_by_name: &HashMap<String, &Json>) -> Vec<String> {
    let lifecycle_field = aggregate.get("lifecycle").and_then(|l| l.get("field")).map(Json::to_s);
    let mut problems: Vec<String> = Vec::new();
    let cmd_attrs = command.get("attributes").map(Json::each).unwrap_or(&[]);

    if crate::shared::creates_owner(aggregate, command, value_objects_by_name) {
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

/// Shared by `emit_command`/`emit_entity_command`.
pub fn invariant_checks_for(exemplar: &Exemplar, command: &Json, aggregates_by_name: &HashMap<String, &Json>, value_objects_by_name: &HashMap<String, &Json>) -> Vec<String> {
    let attrs = command.get("attributes").map(Json::each).unwrap_or(&[]);
    let mut lines: Vec<String> = Vec::new();

    for attr in attrs {
        let field = naming::rust_ident_field(crate::attr::name(attr));

        if !crate::attr::list(attr) {
            // RAW FIELD EXPRESSION, UNCONDITIONALLY — port of `rust/project/
            // commands.rb#invariant_checks_for`'s own fix; see that file's
            // comment for the full argument. `types.rs`'s own value-object-
            // field door passes `self.{field}` raw and never wraps the
            // result itself, trusting `constraints.rs`'s own internal
            // optional-handling to be self-contained — this door used to
            // double-wrap whenever an attribute was BOTH `optional: true`
            // and carried `admits:`/`pattern:`, a real compile failure.
            let value_expr = format!("args.{field}");
            let constraints: Vec<String> = [
                crate::constraints::emit_admits_check(exemplar, &value_expr, attr, aggregates_by_name, value_objects_by_name),
                crate::constraints::emit_pattern_check(exemplar, &value_expr, attr, &crate::attr::name(attr).to_string(), value_objects_by_name),
            ]
            .into_iter()
            .flatten()
            .collect();
            for c in constraints {
                lines.push(format!("        {c}"));
            }
        }

        let vo = value_objects_by_name.get(crate::attr::type_name(attr));
        if let Some(vo) = vo {
            if !vo.get("closed_set").map(Json::as_bool).unwrap_or(false) {
                let line = if crate::attr::optional(attr) {
                    if crate::attr::list(attr) {
                        format!("        if let Some(items) = &args.{field} {{ for item in items {{ item.check_invariants()?; }} }}")
                    } else {
                        format!("        if let Some(v) = &args.{field} {{ v.check_invariants()?; }}")
                    }
                } else if crate::attr::list(attr) {
                    format!("        for item in &args.{field} {{ item.check_invariants()?; }}")
                } else {
                    format!("        args.{field}.check_invariants()?;")
                };
                lines.push(line);
            }
        }
    }

    lines
}

/// A LIST-typed attribute carrying `admits:`/`pattern:` — no real command
/// generates one; skipped loudly rather than silently dropping it.
pub fn constraint_list_problems(command: &Json) -> Vec<String> {
    let attrs = command.get("attributes").map(Json::each).unwrap_or(&[]);
    attrs
        .iter()
        .filter(|attr| crate::attr::list(attr) && (crate::attr::admits(attr).is_some() || crate::attr::pattern(attr).is_some()))
        .map(|attr| format!("{} is a list carrying admits:/pattern: — not generated yet", crate::attr::name(attr)))
        .collect()
}

/// ONE emitter for every command shape `kernel::dispatch` can run.
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
    let given_specs: Vec<String> = givens
        .iter()
        .map(|g| {
            let description = g.get("description").and_then(Json::as_str).unwrap_or("");
            let canonical = g.get("canonical").and_then(Json::as_str).unwrap_or("");
            format!("            crate::kernel::GivenSpec {{ description: {}, expr: {} }},", naming::ruby_inspect_string(description), crate::expr_emitter::emit_predicate(canonical))
        })
        .collect();

    let ensures = command.get("ensures").map(Json::each).unwrap_or(&[]);
    let ensures_specs: Vec<String> = ensures
        .iter()
        .map(|e| {
            let description = e.get("description").and_then(Json::as_str).unwrap_or("");
            let canonical = e.get("canonical").and_then(Json::as_str).unwrap_or("");
            format!("            crate::kernel::EnsuresSpec {{ description: {}, expr: {} }},", naming::ruby_inspect_string(description), crate::expr_emitter::emit_predicate(canonical))
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
    let mut mutation_lines: Vec<String> = mutations_list.iter().map(|m| mutations::emit_mutation_line(exemplar, m, aggregate, command, value_objects_by_name, true)).collect();
    if let Some(t) = &transition {
        if !t.to_state.is_empty() {
            mutation_lines.push(format!("        record.{} = {}.to_string();", naming::rust_ident_field(&t.field), naming::ruby_inspect_string(&t.to_state)));
        }
    }
    if mutation_lines.is_empty() {
        mutation_lines = vec!["        let _ = record;".to_string()];
    }
    let delegation = delegation_of(exemplar, command, aggregate, value_objects_by_name);
    if let Some(d) = &delegation {
        assert!(!creates, "{cmd}: a creating command cannot delegate — nothing exists to delegate to");
        mutation_lines = vec![d.apply.clone()];
    }
    let prelude = delegation.as_ref().map(|d| d.prelude.clone()).unwrap_or_default();
    let payload = if delegation.is_some() { "delegate_facts.clone()," } else { "args.to_json()," }.to_string();

    let (hydrate, fn_signature);
    let record_agg_attrs = aggregate.get("attributes").map(Json::each).unwrap_or(&[]);

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
                            // A CROSS-AGGREGATE argument, same name as the
                            // owner's own field but a DIFFERENT declared
                            // type — see bridging.rs's own header
                            // (`SafeDepositBox.Rent`'s `attribute :customer,
                            // CustomerNumber`, bridged into the owner's own
                            // `customer: Reference<Customer>` field). A
                            // blind `.clone()` here assumed the two types
                            // were always identical, which this generic
                            // name-match never actually required.
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

        hydrate = format!(
            "crate::kernel::Hydrate::Create {{\n        id: {},\n        build: Box::new(|| {record} {{\n{}\n        }}),\n    }}",
            mutations::build_identity_expr(&identity),
            record_fields.join("\n")
        );
        let mut sig_parts = vec![format!("repo: &mut impl crate::kernel::Repository<{record}>")];
        sig_parts.extend(identity_extra_params.iter().cloned());
        sig_parts.push(format!("args: {cmd}Args"));
        sig_parts.push("mutations: &mut Vec<crate::kernel::MutationRecord>".to_string());
        sig_parts.extend(deref_params().iter().map(|s| s.to_string()));
        fn_signature = sig_parts.join(", ");
    } else {
        let mut sig_parts = vec![
            format!("repo: &mut impl crate::kernel::Repository<{record}>"),
            "id: &str".to_string(),
            format!("args: {cmd}Args"),
            "mutations: &mut Vec<crate::kernel::MutationRecord>".to_string(),
        ];
        sig_parts.extend(deref_params().iter().map(|s| s.to_string()));
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
            ("repo: &mut impl crate::kernel::Repository<TmplRecord>, id: &str, args: TmplArgs, mutations: &mut Vec<crate::kernel::MutationRecord>", fn_signature),
            ("dispatch_tmpl", format!("dispatch_{}", naming::dispatch_fn_name(&cmd))),
            ("TmplRecord", record),
            ("tmpl_invariant_check_placeholder()?;", invariant_checks.join("\n")),
            ("let tmpl_eval_fielded = tmpl_with_references_placeholder();", with_references_binding()),
            ("&tmpl_eval_fielded,", "&with_references,".to_string()),
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
            ("tmpl_emit_placeholder()", emits_expr),
            ("args.to_json(),", payload),
        ],
    );

    format!("{}\n\n#[derive(Debug, Clone)]\n{}\n\n{dispatch_fn}", crate::fielded::emit_fielded_flat(exemplar, &format!("{cmd}Args"), attrs, value_objects_by_name, &[]), args_struct.join("\n"))
}

/// Port of commands.rb's `delegate_of`/`delegate_mapping`/
/// `delegate_target`/`delegate_skip_reason`/`delegation_of` — the
/// `:delegate` mutation (`delegates_to`), see the exemplar's own
/// `delegate_prelude`/`delegate_apply` comment for the shape.
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
        if crate::attr::type_name(source) != crate::attr::type_name(attr) || crate::attr::list(source) != crate::attr::list(attr) {
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
    apply: String,
    emits: Vec<String>,
}

fn indent_block(text: &str, indent: &str) -> String {
    text.lines().map(|l| format!("{indent}{l}")).collect::<Vec<_>>().join("\n").trim_end().to_string()
}

fn delegation_of(exemplar: &Exemplar, command: &Json, aggregate: &Json, value_objects_by_name: &HashMap<String, &Json>) -> Option<Delegation> {
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
    let target_args_name = format!("{element_record}{}Args", naming::rust_ident(&target.get("name").map(Json::to_s).unwrap_or_default()));
    let aliases: Vec<String> = delegate_mapping(delegation).iter().map(|(t, s)| format!("({}, {})", naming::ruby_inspect_string(t), naming::ruby_inspect_string(s))).collect();
    let given_specs: Vec<String> = target
        .get("givens")
        .map(Json::each)
        .unwrap_or(&[])
        .iter()
        .map(|g| {
            let description = g.get("description").and_then(Json::as_str).unwrap_or("");
            let canonical = g.get("canonical").and_then(Json::as_str).unwrap_or("");
            format!("            crate::kernel::GivenSpec {{ description: {}, expr: {} }},", naming::ruby_inspect_string(description), crate::expr_emitter::emit_predicate(canonical))
        })
        .collect();
    let ensures_specs: Vec<String> = target
        .get("ensures")
        .map(Json::each)
        .unwrap_or(&[])
        .iter()
        .map(|e| {
            let description = e.get("description").and_then(Json::as_str).unwrap_or("");
            let canonical = e.get("canonical").and_then(Json::as_str).unwrap_or("");
            format!("            crate::kernel::EnsuresSpec {{ description: {}, expr: {} }},", naming::ruby_inspect_string(description), crate::expr_emitter::emit_predicate(canonical))
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
    if let Some(t) = &transition {
        if !t.to_state.is_empty() {
            mutation_lines.push(format!("        record.{} = {}.to_string();", naming::rust_ident_field(&t.field), naming::ruby_inspect_string(&t.to_state)));
        }
    }
    if mutation_lines.is_empty() {
        mutation_lines = vec!["        let _ = record;".to_string()];
    }
    let identity_reading = entity.get("identified_by").map(Json::each).unwrap_or(&[]).iter().map(Json::to_s).collect::<Vec<_>>().join(", ");

    let prelude = exemplar.render(
        "delegate_prelude",
        &[("tmpl_aliases_placeholder()", aliases.join(", ")), ("TmplTargetArgs", target_args_name), ("TmplElement", element_record.clone())],
    );
    let apply = exemplar.render(
        "delegate_apply",
        &[
            ("TmplRecord", naming::rust_ident(&aggregate_name)),
            ("tmpl_list_field", naming::rust_ident_field(crate::attr::name(list_attr))),
            ("TmplElement", element_record),
            // BARE, not "{entity_name}.{target name}" — mirrors
            // rust/project/commands.rb's own identical fix: this feeds
            // straight into refusal-message text, and Ruby's own
            // `command.hecks_name` is never entity-qualified.
            ("\"TmplQualifiedCommandName\"", naming::ruby_inspect_string(&target.get("name").map(Json::to_s).unwrap_or_default())),
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
        apply: indent_block(&apply, "        "),
        emits: target.get("emits").map(Json::each).unwrap_or(&[]).iter().map(Json::to_s).collect(),
    })
}

/// `entity_command_skip_reason` — `command_skip_reason` with `entity`
/// standing in for `aggregate`. Used to unconditionally refuse an
/// entity's own `:append` mutation here, reasoning that `append_element`
/// reads `aggregate.get("entities")`, which an entity node didn't carry
/// at the time this guard was written. It does now (S17, ADR 0026 — an
/// entity's own IR shape is genuinely the same six-key shape an
/// aggregate's is, entities included) — mirrors commands.rb's own
/// identical removal exactly, confirmed the same way: both real corpus
/// targets (`ValueObject::Member.Pair`, a VO-list; `ProcessManager::
/// Handler.Dispatch`, a genuinely nested entity-list) compile and pass
/// codegen_parity_spec against the Ruby-orchestrated generator.
pub fn entity_command_skip_reason(command: &Json, entity: &Json, value_objects_by_name: &HashMap<String, &Json>) -> Option<String> {
    command_skip_reason(command, entity, value_objects_by_name)
}

/// AN ENTITY COMMAND.
pub fn emit_entity_command(
    exemplar: &Exemplar,
    command: &Json,
    entity: &Json,
    parent_aggregate: &Json,
    domain_name: &str,
    value_objects_by_name: &HashMap<String, &Json>,
    aggregates_by_name: &HashMap<String, &Json>,
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
    let args_struct_name = format!("{element_record}{cmd}Args");

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
            let canonical = g.get("canonical").and_then(Json::as_str).unwrap_or("");
            format!("            crate::kernel::GivenSpec {{ description: {}, expr: {} }},", naming::ruby_inspect_string(description), crate::expr_emitter::emit_predicate(canonical))
        })
        .collect();

    let ensures = command.get("ensures").map(Json::each).unwrap_or(&[]);
    let ensures_specs: Vec<String> = ensures
        .iter()
        .map(|e| {
            let description = e.get("description").and_then(Json::as_str).unwrap_or("");
            let canonical = e.get("canonical").and_then(Json::as_str).unwrap_or("");
            format!("            crate::kernel::EnsuresSpec {{ description: {}, expr: {} }},", naming::ruby_inspect_string(description), crate::expr_emitter::emit_predicate(canonical))
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
    if let Some(t) = &transition {
        if !t.to_state.is_empty() {
            mutation_lines.push(format!("        record.{} = {}.to_string();", naming::rust_ident_field(&t.field), naming::ruby_inspect_string(&t.to_state)));
        }
    }
    if mutation_lines.is_empty() {
        mutation_lines = vec!["        let _ = record;".to_string()];
    }

    // BARE, not entity-qualified — same reasoning as delegate_apply's own
    // identical fix above.
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
            ("tmpl_emit_placeholder()", emits_expr),
        ],
    );

    [
        crate::fielded::emit_fielded_flat(exemplar, &args_struct_name, attrs, value_objects_by_name, &[]),
        format!("#[derive(Debug, Clone)]\n{}", args_struct.join("\n")),
        crate::json_codec::emit_to_json_flat(exemplar, &args_struct_name, attrs, value_objects_by_name, false, &[], None),
        crate::json_codec::emit_from_json_flat(exemplar, &args_struct_name, attrs, value_objects_by_name, None, None),
        entity_dispatch_fn,
    ]
    .join("\n\n")
}
