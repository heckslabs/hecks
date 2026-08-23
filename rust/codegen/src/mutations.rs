//! Port of `rust/project/mutations.rb` — read that file's own header
//! comments in full; this mirrors its algorithm directly, function for
//! function. `list_attr_creation_optional?` was already ported to
//! `shared.rs` in the prior stage (two already-ported modules depend on
//! it) — not duplicated here.
//!
//! `mark_append_optional_fields!` is DELIBERATELY NOT PORTED — see
//! `spec/codegen_parity_spec.rb`'s own note: every real corpus field that
//! pass would touch already declares `optional: true` directly in its own
//! bluebook source, so the mutating pass is a no-op everywhere this corpus
//! actually reaches it. `Json` (this crate's own IR value type) has no
//! mutation API to begin with — see `json.rs`'s own header — so a real
//! port would need a materially different (mutable-tree) representation
//! for no currently-observable behavioral gain. Named here as a real,
//! confirmed-currently-harmless gap, exactly like the Ruby-side harness
//! already names it, not silently dropped from consideration.

use crate::exemplar::Exemplar;
use crate::json::Json;
use crate::literal::{self, Literal};
use crate::naming;
use std::collections::HashMap;

/// `append`'s TARGET, resolved to whichever real thing it is — a plain
/// value object or an ENTITY.
///
/// LOCAL (an entity this aggregate declares) FIRST, matching
/// mutations.rb's own header — `value_objects_by_name` is merged DOMAIN-
/// WIDE (every aggregate's own value objects, so a cross-aggregate reuse
/// like Translation's own TranslationName resolves at all), but the two
/// namespaces aren't meant to collide. The self-hosted grammar's own
/// Bluebook chapter proves they CAN: Command's domain-wide value_object
/// "Argument" (an ordinary command's own argument row) and Syntax's own
/// LOCAL entity "Argument" (S14, ADR 0026 — one row of the syntax table
/// itself) share a name purely by coincidence. Checking local first means
/// Syntax's OWN Argument entity resolves correctly; every other
/// aggregate, with no such collision, sees identical behavior either
/// order.
pub fn append_element<'a>(aggregate: &'a Json, target_type: &str, value_objects_by_name: &HashMap<String, &'a Json>) -> Option<&'a Json> {
    if let Some(local) = aggregate.get("entities").map(Json::each).unwrap_or(&[]).iter().find(|e| e.get("name").and_then(Json::as_str) == Some(target_type)) {
        return Some(local);
    }
    value_objects_by_name.get(target_type).copied()
}

/// An entity element's identity, auto-minted at append time — see
/// mutations.rb's own header for the full argument. Returns
/// `(identity_attribute, its_single_field_value_object)`.
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

/// `Marks.read`/`append_field_source` — the exact inverse of `appended_fields`'s
/// own spelling: a leading `:` marks a command ARGUMENT; anything else IS
/// the literal value.
pub fn append_field_source(source: &str) -> Literal {
    literal::read(source)
}

pub fn literal_problem(mutation: &Json, field_name: &str, lit: &Literal, field_attr: &Json, value_objects_by_name: &HashMap<String, &Json>) -> Option<String> {
    if let Literal::Hash(_) = lit {
        if crate::bridging::literal_hash_bridgeable(lit, crate::attr::type_name(field_attr), value_objects_by_name) {
            return None;
        }
    }
    let target = mutation.get("target").map(Json::to_s).unwrap_or_default();
    Some(format!("{target}.{field_name}: literal doesn't bridge to {}", crate::attr::type_name(field_attr)))
}

/// Every `append` mutation's own field(s), checked against the element
/// they're building.
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

/// `m[:fields]` (a JSON object) as an ordered `(key, raw_wire_value)` list
/// — mirrors Ruby's own Hash iteration order (declaration order,
/// preserved by `Json::Object`'s own insertion-ordered pairs).
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
}

/// All transition rows this command names, collapsed into the one
/// `field`/`from_states` shape `TransitionCheck` wants.
pub fn lifecycle_transition_for(command: &Json, aggregate: &Json) -> Option<Transition> {
    let lifecycle = aggregate.get("lifecycle")?;
    let command_name = command.get("name").map(Json::to_s).unwrap_or_default();
    let transitions = lifecycle.get("transitions").map(Json::each).unwrap_or(&[]);
    let rows: Vec<&Json> = transitions.iter().filter(|t| t.get("command").map(Json::to_s).unwrap_or_default() == command_name).collect();
    if rows.is_empty() {
        return None;
    }

    let field = lifecycle.get("field").and_then(Json::as_str).unwrap_or("").to_string();
    let to_state = rows[0].get("to_state").map(Json::to_s).unwrap_or_default();
    let mut from_states: Vec<String> = Vec::new();
    for row in &rows {
        let from = row.get("from_state").map(Json::to_s).unwrap_or_default();
        if !from_states.contains(&from) {
            from_states.push(from);
        }
    }
    Some(Transition { field, to_state, from_states })
}

/// Ruby's real `apply`, for `:set` — coerces whatever arrived into the
/// TARGET attribute's OWN declared type. `source` is `mutation[:source]`
/// (raw JSON — `classified_source`'s own shape, never Literal-rendered).
pub fn mutation_set_rhs(source: &Json, target_type: &str, command: &Json, value_objects_by_name: &HashMap<String, &Json>) -> String {
    if source.get("kind").map(Json::to_s).unwrap_or_default() == "literal" {
        let value = source.get("value").unwrap_or(&Json::Null);
        if let Json::Object(_) = value {
            return crate::bridging::literal_hash_rhs(&Literal::from_json(value), target_type, value_objects_by_name);
        }
        return naming::literal_rhs(value);
    }

    let source_name = source.get("name").map(Json::to_s).unwrap_or_default();
    let cmd_attrs = command.get("attributes").map(Json::each).unwrap_or(&[]);
    let source_attr = cmd_attrs.iter().find(|a| crate::attr::name(a) == source_name).expect("mutation source argument must be a declared command attribute");
    crate::bridging::value_rhs(&format!("args.{}", naming::rust_ident_field(&source_name)), crate::attr::type_name(source_attr), target_type, value_objects_by_name)
}

pub struct IdentityComponent {
    pub expr: String,
    pub param: Option<String>,
    pub head: Option<String>,
}

/// THE IDENTITY IS THE JOIN OF ITS PARTS — see mutations.rb's own header
/// for the full argument on the three component shapes.
///
/// "DECLARED" MEANS the SAME test `creates_owner` (shared.rs, own header)
/// uses to count a field as supplied: a `:set` mutation targeting it, OR
/// a same-named command argument copied straight across by `record_fields`
/// (commands.rb) with no mutation at all — EXCLUDING an argument already
/// claimed by an append (`append_claimed_names`, shared.rs). A "creates"
/// command whose identity head is supplied this second way
/// (`Governance::RoleAssignment.Assign`'s own `actor_id`/`role_name`/
/// `starts_at` — no explicit `:set` at all, bare-name-matched like
/// `Order.CreatePizza`'s whole record) reads `args.<head>` exactly the
/// same as one supplied via an explicit `sets :<head>`. Ported to match
/// mutations.rb exactly, including its `.to_string()` on the external
/// branch's own expr — the ONE combination (single identity component,
/// entirely external) that otherwise leaves a bare `&str` where `String`
/// is expected.
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

/// One `append` field's value.
pub fn append_field_rhs(source: &str, field_attr: &Json, command: &Json, value_objects_by_name: &HashMap<String, &Json>) -> String {
    let parsed = append_field_source(source);
    let Literal::Symbol(arg_name) = &parsed else {
        return crate::bridging::literal_hash_rhs(&parsed, crate::attr::type_name(field_attr), value_objects_by_name);
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

/// THE OPTIONAL HALF of `value_rhs`.
pub fn optional_value_rhs(source_expr: &str, source_type: &str, target_type: &str, value_objects_by_name: &HashMap<String, &Json>) -> String {
    format!("{source_expr}.clone().map(|v| {})", crate::bridging::value_rhs("v", source_type, target_type, value_objects_by_name))
}

/// `:append` and `:set` — the two `sets` ops this slice generates.
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

            if let Some(entity) = entity {
                let mut present: Vec<String> = fields.iter().map(|(k, _)| k.clone()).collect();
                if let Some((id_attr, id_vo)) = entity_identity_mint(entity, value_objects_by_name) {
                    let id_name = crate::attr::name(id_attr);
                    if !present.iter().any(|p| p == id_name) {
                        let id_vo_attrs = id_vo.get("attributes").map(Json::each).unwrap_or(&[]);
                        let mint = format!(
                            "{} {{ {}: (record.{target_field}.len() as i64) + 1 }}",
                            naming::rust_ident(crate::attr::type_name(id_attr)),
                            naming::rust_ident_field(crate::attr::name(&id_vo_attrs[0]))
                        );
                        fields_assignment.push(format!("{}: {mint}", naming::rust_ident_field(id_name)));
                        present.push(id_name.to_string());
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

                // A THIRD field no `append: { ... }` binding ever names, on
                // top of the two above: a LIST-typed attribute the entity
                // declares for some OTHER command to `append`/`remove` into
                // later (`ValueObject::Member#pairs`, bound only by its own
                // `Pair` command — S17, ADR 0026). Mirrors the identical fix
                // in rust/project/mutations.rb's own `emit_mutation_line_body`
                // exactly — this is a SEPARATE, independent implementation of
                // the same codegen (Stage 8's opt-in `hecks-codegen` pipeline),
                // and codegen_parity_spec holds the two byte-identical, so a
                // gap fixed in one and not the other is a real, caught
                // divergence, not a hypothetical one.
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
            }

            exemplar.render("mutation_append", &[("tmpl_field", target_field.to_string()), ("tmpl_fields_placeholder()", format!("{vo_type} {{ {} }}", fields_assignment.join(", ")))])
        }
        "set" => {
            if lifecycle_field.map(|f| f == target_name).unwrap_or(false) {
                let rhs = mutation_set_rhs(mutation.get("source").unwrap_or(&Json::Null), "String", command, value_objects_by_name);
                exemplar.render("mutation_set_plain", &[("tmpl_field", target_field.to_string()), ("tmpl_rhs_placeholder2()", rhs)])
            } else {
                let attrs = aggregate.get("attributes").map(Json::each).unwrap_or(&[]);
                let target_attr = attrs.iter().find(|a| crate::attr::name(a) == target_name).expect("set target must be a declared aggregate attribute");
                let rhs = mutation_set_rhs(mutation.get("source").unwrap_or(&Json::Null), crate::attr::type_name(target_attr), command, value_objects_by_name);
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
                    exemplar.render("mutation_set_plain", &[("tmpl_field", target_field.to_string()), ("tmpl_rhs_placeholder2()", rhs)])
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
            // THE IR'S OWN sign FIELD, not re-derived from the op NAME —
            // port of rust/project/mutations.rb's own fix; see that
            // file's comment for the full argument.
            let sign = if mutation.get("sign").map(Json::to_s).unwrap_or_default() == "1" { "+" } else { "-" };
            let current = if optional { format!("record.{target_field}.clone().unwrap()") } else { format!("record.{target_field}.clone()") };
            let updated = format!("{vo_type} {{ {field_ident}: current.{field_ident} {sign} ({amount_expr}), ..current }}");
            exemplar.render(
                "mutation_arithmetic",
                &[("tmpl_field", target_field.to_string()), ("tmpl_current_placeholder()", current), ("tmpl_updated_placeholder()", if optional { format!("Some({updated})") } else { updated })],
            )
        }
        other => panic!("unsupported mutation op {other:?} — command_skip_reason should have caught this"),
    }
}
