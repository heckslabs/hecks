//! Command router emitter, ported from `rust/project/registry.rb`.
//! The entry structs mirror the Hashes `domain_generator.rb` accumulates while walking the IR.

use crate::exemplar::Exemplar;
use crate::naming;
use crate::reference_specs::{self, ReferenceSpec};

#[derive(Clone)]
pub struct ReferenceCheck {
    pub field: String,
    pub optional: bool,
    /// `Some(element key expression)` for a list (`has_many`) check.
    pub list_item: Option<String>,
    pub target_mod: String,
    pub target_name: String,
    pub heads: String,
}

/// One write-side tenant boundary check (`domain_generator.rb#tenant_boundary_checks`), typed.
pub struct TenantBoundaryCheck {
    pub reference_field: String,
    pub target_mod: String,
    pub target_name: String,
    pub aggregate_name: String,
    pub own_tenant_field: String,
    pub own_accessor: String,
    pub target_tenant_field: String,
    pub target_accessor: String,
}

pub struct CommandEntry {
    pub verb: String,
    pub name: String,
    pub fn_name: String,
    pub args_struct: String,
    pub creates: bool,
    pub identity_extra_params: Vec<String>,
    pub reference_checks: Vec<ReferenceCheck>,
    /// Write-side tenant boundary checks run before dispatch.
    pub tenant_boundary_checks: Vec<TenantBoundaryCheck>,
    /// Reference-typed attributes, the specs behind `command_deref`.
    pub reference_specs: Vec<ReferenceSpec>,
    /// Declared attribute names; read by `reactions.rs#emit_command_attributes_table`.
    pub attributes: Vec<String>,
    /// Value-object invariant/admits/pattern checks as ready-to-splice lines, run before the
    /// role and reference checks. `commands.rs::emit_command` repeats them in the dispatch fn.
    pub invariant_check_lines: Vec<String>,
    pub role: Option<String>,
}

pub struct EntityCommandEntry {
    pub verb: String,
    pub name: String,
    pub entity_record: String,
    pub fn_name: String,
    pub args_struct: String,
    pub reference_checks: Vec<ReferenceCheck>,
    pub reference_specs: Vec<ReferenceSpec>,
    /// Declared attribute names; see `CommandEntry`.
    pub attributes: Vec<String>,
    /// See `CommandEntry::invariant_check_lines`.
    pub invariant_check_lines: Vec<String>,
    pub role: Option<String>,
    /// Carried for shape parity with `domain_generator.rb`'s `entity_commands`; unread here.
    pub entity_name: String,
    pub entity_identity_reading: String,
}

/// A command owned by an entity nested two levels deep (`Aggregate.Entity.Entity.Command`).
/// Adds the innermost entity's name and identity reading to `EntityCommandEntry`'s fields.
pub struct NestedEntityCommandEntry {
    pub verb: String,
    pub name: String,
    pub entity_record: String,
    pub nested_record: String,
    pub fn_name: String,
    pub args_struct: String,
    pub reference_checks: Vec<ReferenceCheck>,
    pub reference_specs: Vec<ReferenceSpec>,
    pub attributes: Vec<String>,
    pub invariant_check_lines: Vec<String>,
    pub role: Option<String>,
    pub entity_name: String,
    pub entity_identity_reading: String,
    pub nested_name: String,
    pub nested_identity_reading: String,
    /// Whether the router gets a flat-args (`None`) fallback for this command; true only when both
    /// hops' identity is `extract_id`-supported.
    pub unrouted_supported: bool,
}

pub struct PortEntry {
    pub verb: String,
    pub name: String,
    pub fn_name: String,
    pub args_struct: String,
    pub reference_checks: Vec<ReferenceCheck>,
    /// Self-reference field from older port IR; new operations take the owner from the route.
    pub legacy_receiver_field: Option<String>,
    /// Receiver field of `to:`-declared operations; a real attribute, kept in the payload.
    pub to_receiver_field: Option<String>,
}

/// A nested entity's name and identity paths, from `domain_generator.rb`'s `entities:` field.
/// `reactions.rs#emit_entity_identity_head_table` reads the single-component case.
pub struct EntityIdentityEntry {
    pub name: String,
    pub identified_by: Vec<String>,
}

pub struct AggregateEntry {
    pub name: String,
    pub module_name: String,
    pub record: String,
    pub commands: Vec<CommandEntry>,
    pub entity_commands: Vec<EntityCommandEntry>,
    pub nested_entity_commands: Vec<NestedEntityCommandEntry>,
    pub ports: Vec<PortEntry>,
    pub chapter_mod: String,
    pub domain_name: String,
    /// Reference-typed attributes; this aggregate's row in `REFERENCE_TABLE`.
    pub reference_specs: Vec<ReferenceSpec>,
    /// Declared identity paths; `reactions.rs#emit_identity_head_table` reads one-component ones.
    pub identified_by: Vec<String>,
    /// Nested entities, read by `reactions.rs#emit_entity_identity_head_table`.
    pub entities: Vec<EntityIdentityEntry>,
}

pub fn emit_role_check(
    exemplar: &Exemplar,
    role: Option<&str>,
    command_name: &str,
) -> Option<String> {
    let role = role?;
    Some(exemplar.render(
        "role_check",
        &[
            ("\"TmplRole\"", naming::ruby_inspect_string(role)),
            (
                "\"TmplCommandName\"",
                naming::ruby_inspect_string(command_name),
            ),
        ],
    ))
}

/// Port of `rust/project/registry.rb#emit_tenant_boundary_check`.
/// Hand-built: the target accessor differs for a single-attribute value object and a bare scalar.
pub fn emit_tenant_boundary_check(check: &TenantBoundaryCheck) -> String {
    let ref_ident = naming::rust_ident_field(&check.reference_field);
    let own_expr = format!("args.{}.clone()", naming::rust_ident_field(&check.own_accessor));
    let target_expr = match check.target_accessor.split_once('.') {
        Some((head, inner)) => format!(
            "record.{}.as_ref().map(|v| v.{}.clone())",
            naming::rust_ident_field(head),
            naming::rust_ident_field(inner)
        ),
        None => format!("record.{}.clone()", naming::rust_ident_field(&check.target_accessor)),
    };

    let mut out = String::new();
    out.push_str(&format!("if let Some(record) = store.{}.find(&args.{ref_ident}) {{ ", check.target_mod));
    out.push_str(&format!("if let Some(target_tenant) = {target_expr} {{ "));
    out.push_str(&format!("let own_tenant = {own_expr}; "));
    out.push_str("if target_tenant != own_tenant { ");
    out.push_str(
        "return Err(crate::kernel::Refusal::Unauthorized(crate::kernel::refusal_wording::UnauthorizedCrossTenantReferenceArgs { ",
    );
    out.push_str(&format!("aggregate: {}, ", naming::ruby_inspect_string(&check.aggregate_name)));
    out.push_str(&format!("field: {}, ", naming::ruby_inspect_string(&check.own_tenant_field)));
    out.push_str("tenant: &format!(\"{:?}\", own_tenant), ");
    out.push_str(&format!("attribute: {}, ", naming::ruby_inspect_string(&check.reference_field)));
    out.push_str(&format!("target: {}, ", naming::ruby_inspect_string(&check.target_name)));
    out.push_str(&format!("target_field: {}, ", naming::ruby_inspect_string(&check.target_tenant_field)));
    out.push_str("other: &format!(\"{:?}\", target_tenant)");
    out.push_str(" }.render_args())); ");
    out.push_str("} } }");
    out
}

/// `kernel::ArgumentGates` literal for one command (`registry.rb#emit_argument_gates_literal`).
/// The last two fields are closures because they need `store`, which exists only at the router.
fn emit_argument_gates_literal(args_path: &str, invariant_check_lines: &[String], role_line: Option<String>, reference_lines: &[String]) -> String {
    let mut normalize = vec![format!("let args = {args_path}::from_json(v)?;")];
    normalize.extend(invariant_check_lines.iter().map(|l| squeeze(l)));
    normalize.push("Ok(args)".to_string());

    let role = match role_line.filter(|l| !l.is_empty()) {
        Some(line) => format!("&|| {{ {} Ok(()) }}", squeeze(&line)),
        None => "&|| Ok(())".to_string(),
    };
    let references: Vec<String> = reference_lines.iter().filter(|l| !l.is_empty()).map(|l| squeeze(l)).collect();
    let references = if references.is_empty() {
        format!("&|_args: &{args_path}| Ok(())")
    } else {
        format!("&|args: &{args_path}| {{ {} Ok(()) }}", references.join(" "))
    };

    format!(
        "crate::kernel::ArgumentGates {{ decode_arguments: &{args_path}::decode_arguments, \
         refuse_unknown_arguments: &{args_path}::refuse_unknown_arguments, \
         refuse_absent_arguments: &{args_path}::refuse_absent_arguments, \
         normalize_args: &|v: &crate::kernel::Json| {{ {} }}, refuse_role_mismatch: {role}, resolve_references: {references} }}",
        normalize.join(" ")
    )
}

/// Joins a multi-line emitted check onto one line so it can sit inside a closure expression.
fn squeeze(text: &str) -> String {
    text.lines().map(str::trim).filter(|l| !l.is_empty()).collect::<Vec<_>>().join(" ")
}

pub fn emit_reference_check(exemplar: &Exemplar, check: &ReferenceCheck) -> String {
    let ident = naming::rust_ident_field(&check.field);
    if let Some(list_item) = &check.list_item {
        exemplar.render(
            "reference_check_list",
            &[
                (
                    "\"TmplTarget\"",
                    naming::ruby_inspect_string(&check.target_name),
                ),
                ("\"tmpl_heads\"", naming::ruby_inspect_string(&check.heads)),
                ("tmpl_target_mod", check.target_mod.clone()),
                ("tmpl_list_field", ident),
                ("&item.tmpl_element_field", list_item.clone()),
            ],
        )
    } else if check.optional {
        exemplar.render(
            "reference_check_optional",
            &[
                (
                    "\"TmplTarget\"",
                    naming::ruby_inspect_string(&check.target_name),
                ),
                ("\"tmpl_heads\"", naming::ruby_inspect_string(&check.heads)),
                ("tmpl_target_mod", check.target_mod.clone()),
                ("tmpl_optional_field", ident),
            ],
        )
    } else {
        exemplar.render(
            "reference_check_required",
            &[
                (
                    "\"TmplTarget\"",
                    naming::ruby_inspect_string(&check.target_name),
                ),
                ("\"tmpl_heads\"", naming::ruby_inspect_string(&check.heads)),
                ("tmpl_target_mod", check.target_mod.clone()),
                ("tmpl_field", ident),
            ],
        )
    }
}

fn chapter_path(a: &AggregateEntry) -> String {
    format!("crate::generated::{}::{}", a.chapter_mod, a.module_name)
}

pub fn emit_registry(exemplar: &Exemplar, aggregates: &[AggregateEntry]) -> String {
    let store_fields: Vec<String> = aggregates
        .iter()
        .map(|a| {
            format!(
                "    pub {}: crate::kernel::InMemoryRepository<{}::{}>,",
                a.module_name,
                chapter_path(a),
                a.record
            )
        })
        .collect();
    let store_inits: Vec<String> = aggregates
        .iter()
        .map(|a| {
            format!(
                "            {}: crate::kernel::InMemoryRepository::new(),",
                a.module_name
            )
        })
        .collect();

    let dump_arms: Vec<String> = aggregates
        .iter()
        .map(|a| {
            let prefix = format!("{}::{}#", a.domain_name, a.name);
            format!(
                "for (id, record) in self.{}.entries() {{\n    instances.push((format!(\"{{}}{{}}\", {}, id), record.to_json()));\n}}",
                a.module_name,
                naming::ruby_inspect_string(&prefix)
            )
        })
        .collect();

    let seed_arms: Vec<String> = aggregates
        .iter()
        .map(|a| {
            let mod_path = chapter_path(a);
            let prefix = format!("{}::{}#", a.domain_name, a.name);
            format!(
                "if let Some(id) = key.strip_prefix({}) {{\n    store.{}.save(id, {mod_path}::{}::from_json(value)?);\n    continue;\n}}",
                naming::ruby_inspect_string(&prefix),
                a.module_name,
                a.record
            )
        })
        .collect();

    let query_arms: Vec<String> = aggregates
        .iter()
        .map(|a| {
            let prefix = format!("{}::{}", a.domain_name, a.name);
            format!(
                "if aggregate == {} {{\n    return Some(self.{}.json_entries(|record| record.to_json()).map(|(id, json)| (id.clone(), json.clone())).collect());\n}}",
                naming::ruby_inspect_string(&prefix),
                a.module_name
            )
        })
        .collect();

    let scan_each_arms: Vec<String> = aggregates
        .iter()
        .map(|a| {
            let prefix = format!("{}::{}", a.domain_name, a.name);
            format!(
                "if aggregate == {} {{\n    for (id, json) in self.{}.json_entries(|record| record.to_json()) {{\n        visit(id, json);\n    }}\n    return true;\n}}",
                naming::ruby_inspect_string(&prefix),
                a.module_name
            )
        })
        .collect();

    let mut aggregate_arms: Vec<String> = Vec::new();
    for a in aggregates {
        let mod_path = chapter_path(a);
        for c in &a.commands {
            let extra_names = &c.identity_extra_params;
            let extra_idents: Vec<String> = extra_names
                .iter()
                .map(|n| naming::rust_ident_field(n))
                .collect();
            let extra_lines: Vec<String> = extra_names
                .iter()
                .zip(extra_idents.iter())
                .map(|(name, ident)| {
                    let msg = format!("{} creates a {} — pass {name}", c.verb, a.record);
                    format!(
                        "let {ident} = facts_json.dig({}).ok_or_else(|| crate::kernel::Refusal::NotFound({}.to_string()))?.to_id_component()?;",
                        naming::ruby_inspect_string(name),
                        naming::ruby_inspect_string(&msg)
                    )
                })
                .collect();
            let extra_pass: String = extra_idents
                .iter()
                .map(|ident| format!("&{ident}, "))
                .collect();

            // A creating command's dispatch fn takes `route` so it can tell create from find.
            let dispatch_call = format!(
                "{mod_path}::dispatch_{}(&mut store.{}, {}args, mutations, owner_deref, command_deref, tenant_boundary_check)",
                c.fn_name,
                a.module_name,
                if c.creates { format!("route, {extra_pass}") } else { "&id, ".to_string() }
            );
            // `extract_id` has no command context to render `NotFoundActingNoIdentity`, so its Err
            // is wrapped here into the wording Ruby's `acting_no_identity` refusal produces.
            let not_found_expr = |command: &str, aggregate: &str, identity: &str| {
                format!(
                    "crate::kernel::Refusal::NotFound(crate::kernel::refusal_wording::NotFoundActingNoIdentityArgs {{ command: {}, aggregate: {}, identity: {} }}.render_args())",
                    naming::ruby_inspect_string(command),
                    naming::ruby_inspect_string(aggregate),
                    naming::ruby_inspect_string(identity)
                )
            };
            // Route depth is checked eagerly. With an explicit `with:` Ruby validates facts before
            // the route, so `args_line` picks the order at runtime. Identity follows every gate.
            let route_precheck_line =
                "if let Some(route) = route { route.require_depth(0)?; }".to_string();
            let id_line = if c.creates {
                String::new()
            } else {
                let not_found = not_found_expr(&c.name, &a.record, &a.identified_by.join(", "));
                format!(
                    "let id = match route {{ Some(route) => route.aggregate().to_string(), None => {mod_path}::{}::extract_id(facts_json).map_err(|_| {not_found})?, }};",
                    a.record
                )
            };
            // The argument gates go to the kernel, which runs them in `AggregateStep::ORDER`.
            let gates_expr = format!(
                "crate::kernel::decode_aggregate_arguments(facts_json, &{})?",
                emit_argument_gates_literal(
                    &format!("{mod_path}::{}", c.args_struct),
                    &c.invariant_check_lines,
                    emit_role_check(exemplar, c.role.as_deref(), &c.name),
                    &c
                        .reference_checks
                        .iter()
                        .map(|check| emit_reference_check(exemplar, check))
                        .collect::<Vec<_>>()
                )
            );
            // One `if` expression, so exactly one of the two orders runs per call.
            let args_line = format!(
                "let args = if invocation.explicit_with() {{ let args = {gates_expr}; {route_precheck_line} args }} \
                 else {{ {route_precheck_line} {gates_expr} }};"
            );

            // Checks come from `ir.json` at codegen time; none means `Ok(())`, else one closure.
            let tenant_boundary_check_bodies: Vec<String> = c
                .tenant_boundary_checks
                .iter()
                .map(emit_tenant_boundary_check)
                .collect();
            let tenant_boundary_check_line = if tenant_boundary_check_bodies.is_empty() {
                "let tenant_boundary_check: Result<(), crate::kernel::Refusal> = Ok(());".to_string()
            } else {
                format!(
                    "let tenant_boundary_check: Result<(), crate::kernel::Refusal> = \
                     (|| -> Result<(), crate::kernel::Refusal> {{ {} Ok(()) }})();",
                    tenant_boundary_check_bodies.join(" ")
                )
            };

            // Resolved before the `&mut store.<mod>` borrow below; it needs `store` whole.
            let owner_deref_expr = if c.creates {
                "Vec::new()".to_string()
            } else {
                format!(
                    "crate::kernel::owner_deref(&*store, REFERENCE_TABLE, {}, &id)",
                    naming::ruby_inspect_string(&format!("{}::{}", a.domain_name, a.name))
                )
            };
            let deref_lines = vec![
                format!("let owner_deref = {owner_deref_expr};"),
                format!(
                    "let command_deref = crate::kernel::command_deref(&*store, REFERENCE_TABLE, {}, &args);",
                    reference_specs::emit_reference_specs_literal(&c.reference_specs)
                ),
            ];

            let mut body: Vec<String> = vec![
                "let invocation = crate::kernel::CommandInvocation::from_json(args_json)?;"
                    .to_string(),
                "let route = invocation.route();".to_string(),
                "let facts_json = invocation.facts();".to_string(),
            ];
            body.push(args_line);
            // Identity after the gates; `extra_lines` read identity-extra heads, so they follow.
            if !id_line.is_empty() {
                body.push(id_line);
            }
            body.extend(extra_lines);
            body.push(tenant_boundary_check_line);
            body.extend(deref_lines);
            body.push(
                "let payload = crate::kernel::Json::overlay(facts_json, &args.to_json());"
                    .to_string(),
            );
            body.push(format!(
                "{dispatch_call}.map(|(_, events)| stamp_payload(events, &payload))"
            ));

            aggregate_arms.push(format!(
                "          {} => {{\n{}\n          }}",
                naming::ruby_inspect_string(&c.verb),
                body.iter()
                    .map(|l| format!("              {l}"))
                    .collect::<Vec<_>>()
                    .join("\n")
            ));
        }
    }

    let mut entity_arms: Vec<String> = Vec::new();
    for a in aggregates {
        let mod_path = chapter_path(a);
        for c in &a.entity_commands {
            // The argument gates; `kernel::decode_entity_arguments` walks `EntityStep::ORDER`.
            let gates_line = format!(
                "let args = crate::kernel::decode_entity_arguments(facts_json, &{})?;",
                emit_argument_gates_literal(
                    &format!("{mod_path}::{}", c.args_struct),
                    &c.invariant_check_lines,
                    emit_role_check(exemplar, c.role.as_deref(), &c.name),
                    &c
                        .reference_checks
                        .iter()
                        .map(|check| emit_reference_check(exemplar, check))
                        .collect::<Vec<_>>()
                )
            );
            let dispatch_call = format!(
                "{mod_path}::dispatch_entity_{}(&mut store.{}, &parent_id, &element_id, &element_wants, args, mutations, owner_deref, command_deref).map(|(_, events)| stamp_payload(events, &payload))",
                c.fn_name, a.module_name
            );

            // Gates run before identity for routed and unrouted calls alike; the eager
            // `route.require_depth(1)?` makes a wrong-depth `to:` refuse first, as in Ruby.
            // A missing identity is wrapped as NotFound, as in the aggregate arm's `id_line`.
            let entity_parent_no_identity_message = format!(
                "{} acts on a {}'s {} — pass {}:",
                c.name, a.record, c.entity_name, a.identified_by.join(", ")
            );
            let entity_element_no_identity_message = format!(
                "{} acts on one {} — pass {}:",
                c.name, c.entity_name, c.entity_identity_reading
            );
            // `element_id` uses `extract_id_lenient` (absent vs blank element identity);
            // `parent_id` stays strict.
            let body_entity_match = format!(
                "let (parent_id, element_id, element_wants) = match route {{ Some(route) => {{ let element_id = route.entities()[0].clone(); (route.aggregate().to_string(), element_id.clone(), element_id) }}, None => {{ let parent_id = {mod_path}::{}::extract_id(facts_json).map_err(|_| crate::kernel::Refusal::NotFound({}.to_string()))?; let element_id = {mod_path}::{}::extract_id_lenient(facts_json).map_err(|_| crate::kernel::Refusal::NotFound({}.to_string()))?; let element_wants = {mod_path}::{}::extract_wants(facts_json); (parent_id, element_id, element_wants) }}, }};",
                a.record,
                naming::ruby_inspect_string(&entity_parent_no_identity_message),
                c.entity_record,
                naming::ruby_inspect_string(&entity_element_no_identity_message),
                c.entity_record
            );

            let mut body: Vec<String> = vec![
                "let invocation = crate::kernel::CommandInvocation::from_json(args_json)?;".to_string(),
                "let route = invocation.route();".to_string(),
                "let facts_json = invocation.facts();".to_string(),
                "if let Some(route) = route { route.require_depth(1)?; }".to_string(),
                gates_line,
                body_entity_match,
            ];
            // `owner_deref` dereferences the parent's reference fields off `parent_id`, so
            // `seeded_projections` can re-seed them on every entity-command save. `command_deref`
            // also carries the parent's dereferenced state under one "parent" key.
            body.push(format!(
                "let owner_deref = crate::kernel::owner_deref(&*store, REFERENCE_TABLE, {}, &parent_id);",
                naming::ruby_inspect_string(&format!("{}::{}", a.domain_name, a.name))
            ));
            body.push(format!(
                "let mut command_deref = crate::kernel::command_deref(&*store, REFERENCE_TABLE, {}, &args);",
                reference_specs::emit_reference_specs_literal(&c.reference_specs)
            ));
            body.push(format!(
                "if let Some(parent_node) = crate::kernel::parent_deref(&*store, REFERENCE_TABLE, {}, &parent_id) {{ command_deref.push((\"parent\", parent_node)); }}",
                naming::ruby_inspect_string(&format!("{}::{}", a.domain_name, a.name))
            ));
            body.push(
                "let payload = crate::kernel::Json::overlay(facts_json, &args.to_json());"
                    .to_string(),
            );
            body.push(dispatch_call);

            entity_arms.push(format!(
                "          {} => {{\n{}\n          }}",
                naming::ruby_inspect_string(&c.verb),
                body.iter()
                    .map(|l| format!("              {l}"))
                    .collect::<Vec<_>>()
                    .join("\n")
            ));
        }
    }

    // Commands owned by an entity nested two levels deep. `c.unrouted_supported` selects a binding
    // that accepts a route or flat args; otherwise the command is routed-only.
    let mut nested_entity_arms: Vec<String> = Vec::new();
    for a in aggregates {
        let mod_path = chapter_path(a);
        for c in &a.nested_entity_commands {
            // The argument gates; see the entity arm's `gates_line`.
            let gates_line = format!(
                "let args = crate::kernel::decode_entity_arguments(facts_json, &{})?;",
                emit_argument_gates_literal(
                    &format!("{mod_path}::{}", c.args_struct),
                    &c.invariant_check_lines,
                    emit_role_check(exemplar, c.role.as_deref(), &c.name),
                    &c
                        .reference_checks
                        .iter()
                        .map(|check| emit_reference_check(exemplar, check))
                        .collect::<Vec<_>>()
                )
            );
            let dispatch_call = format!(
                "{mod_path}::dispatch_entity_{}(&mut store.{}, &parent_id, &hop1_id, &hop1_wants, &hop2_id, &hop2_wants, args, mutations, owner_deref, command_deref).map(|(_, events)| stamp_payload(events, &payload))",
                c.fn_name, a.module_name
            );

            // Gates before identity, as in `entity_arms`; `route.require_depth(2)?` refuses a
            // wrong-depth route first. A missing identity wraps into a per-hop NotFound message.
            let entity_parent_no_identity_message = format!(
                "{} acts on a {}'s {}.{} — pass {}:",
                c.name, a.record, c.entity_name, c.nested_name, a.identified_by.join(", ")
            );
            let hop1_no_identity_message = format!(
                "{} acts on one {} — pass {}:",
                c.name, c.entity_name, c.entity_identity_reading
            );
            let hop2_no_identity_message = format!(
                "{} acts on one {} — pass {}:",
                c.name, c.nested_name, c.nested_identity_reading
            );
            // Both hops resolve through `extract_id_lenient`; `parent_id` stays strict.
            let route_binding = if c.unrouted_supported {
                format!(
                    "let (parent_id, hop1_id, hop1_wants, hop2_id, hop2_wants) = match route {{ Some(route) => {{ let hop1_id = route.entities()[0].clone(); let hop2_id = route.entities()[1].clone(); (route.aggregate().to_string(), hop1_id.clone(), hop1_id, hop2_id.clone(), hop2_id) }}, None => {{ let parent_id = {mod_path}::{}::extract_id(facts_json).map_err(|_| crate::kernel::Refusal::NotFound({}.to_string()))?; let hop1_id = {mod_path}::{}::extract_id_lenient(facts_json).map_err(|_| crate::kernel::Refusal::NotFound({}.to_string()))?; let hop1_wants = {mod_path}::{}::extract_wants(facts_json); let hop2_id = {mod_path}::{}::extract_id_lenient(facts_json).map_err(|_| crate::kernel::Refusal::NotFound({}.to_string()))?; let hop2_wants = {mod_path}::{}::extract_wants(facts_json); (parent_id, hop1_id, hop1_wants, hop2_id, hop2_wants) }}, }};",
                    a.record,
                    naming::ruby_inspect_string(&entity_parent_no_identity_message),
                    c.entity_record,
                    naming::ruby_inspect_string(&hop1_no_identity_message),
                    c.entity_record,
                    c.nested_record,
                    naming::ruby_inspect_string(&hop2_no_identity_message),
                    c.nested_record
                )
            } else {
                let route_error = format!(
                    "{} addresses an entity nested two levels deep — requires an explicit to: {{ aggregate:, entities: [...] }} route",
                    c.verb
                );
                format!(
                    "let route = route.ok_or_else(|| crate::kernel::Refusal::TypeMismatch({}.to_string()))?; let parent_id = route.aggregate().to_string(); let hop1_id = route.entities()[0].clone(); let hop2_id = route.entities()[1].clone(); let hop1_wants = hop1_id.clone(); let hop2_wants = hop2_id.clone();",
                    naming::ruby_inspect_string(&route_error)
                )
            };

            let mut body: Vec<String> = vec![
                "let invocation = crate::kernel::CommandInvocation::from_json(args_json)?;".to_string(),
                "let route = invocation.route();".to_string(),
                "let facts_json = invocation.facts();".to_string(),
            ];
            body.push("if let Some(route) = route { route.require_depth(2)?; }".to_string());
            body.push(gates_line);
            body.push(route_binding);
            // `owner_deref` uses the top-level aggregate's reference fields, since projection
            // seeding scopes to it, not to the nested entity.
            body.push(format!(
                "let owner_deref = crate::kernel::owner_deref(&*store, REFERENCE_TABLE, {}, &parent_id);",
                naming::ruby_inspect_string(&format!("{}::{}", a.domain_name, a.name))
            ));
            body.push(format!(
                "let command_deref = crate::kernel::command_deref(&*store, REFERENCE_TABLE, {}, &args);",
                reference_specs::emit_reference_specs_literal(&c.reference_specs)
            ));
            body.push(
                "let payload = crate::kernel::Json::overlay(facts_json, &args.to_json());"
                    .to_string(),
            );
            body.push(dispatch_call);

            nested_entity_arms.push(format!(
                "          {} => {{\n{}\n          }}",
                naming::ruby_inspect_string(&c.verb),
                body.iter()
                    .map(|l| format!("              {l}"))
                    .collect::<Vec<_>>()
                    .join("\n")
            ));
        }
    }

    let mut port_arms: Vec<String> = Vec::new();
    for a in aggregates {
        let mod_path = chapter_path(a);
        for p in &a.ports {
            let reference_lines: Vec<String> = p
                .reference_checks
                .iter()
                .map(|check| emit_reference_check(exemplar, check))
                .collect();
            let dispatch_call = format!("{mod_path}::dispatch_operation_{}(&id, args).map(|events| stamp_payload(events, &payload))", p.fn_name);
            let legacy_receiver = p
                .legacy_receiver_field
                .as_deref()
                .map(naming::ruby_inspect_string)
                .map(|field| format!("Some({field})"))
                .unwrap_or_else(|| "None".to_string());
            let to_receiver = p
                .to_receiver_field
                .as_deref()
                .map(naming::ruby_inspect_string)
                .map(|field| format!("Some({field})"))
                .unwrap_or_else(|| "None".to_string());

            let mut body: Vec<String> = vec![
                "let invocation = crate::kernel::CommandInvocation::from_json(args_json)?;".to_string(),
                format!("let (id, port_facts) = invocation.split_aggregate_receiver({legacy_receiver}, {to_receiver})?;"),
                "let facts_json = &port_facts;".to_string(),
                format!(
                    "let _instance = store.{}.find(&id).ok_or_else(|| crate::kernel::Refusal::NotFound(format!(\"{} {{:?}} does not exist\", id)))?;",
                    a.module_name, a.name
                ),
                format!("let args = {mod_path}::{}::from_json(facts_json)?;", p.args_struct),
            ];
            body.extend(reference_lines);
            body.push(
                "let payload = crate::kernel::Json::overlay(facts_json, &args.to_json());"
                    .to_string(),
            );
            body.push(dispatch_call);

            port_arms.push(format!(
                "          {} => {{\n{}\n          }}",
                naming::ruby_inspect_string(&p.verb),
                body.iter()
                    .map(|l| format!("              {l}"))
                    .collect::<Vec<_>>()
                    .join("\n")
            ));
        }
    }

    let mut dispatch_arms = aggregate_arms;
    dispatch_arms.extend(entity_arms);
    dispatch_arms.extend(nested_entity_arms);
    dispatch_arms.extend(port_arms);

    let header = "// GENERATED by bin/project_rust — the JSON command router\n// `kernel::cli` dispatches every step through. Do not hand-edit —\n// re-run bin/project_rust instead.\n#![allow(dead_code, unused_variables)]\n\n// `Repository::save` (from_seed, below) is a TRAIT method —\n// `InMemoryRepository`'s own inherent methods (entries(), used\n// by instances()) need no import, but save() does.\nuse crate::kernel::Repository;\n\n";

    let body = exemplar.render(
        "registry_file",
        &[
            ("TmplStore2", "Store".to_string()),
            (
                "    pub tmpl_field: crate::kernel::InMemoryRepository<i64>,",
                store_fields.join("\n"),
            ),
            (
                "            tmpl_field: tmpl_store_fields_placeholder(),",
                store_inits.join("\n"),
            ),
            ("tmpl_dump_arm_placeholder();", dump_arms.join("\n")),
            ("tmpl_seed_arm_placeholder();", seed_arms.join("\n")),
            ("tmpl_query_arm_placeholder();", query_arms.join("\n")),
            ("tmpl_scan_each_arm_placeholder();", scan_each_arms.join("\n")),
            (
                "\"tmpl_verb\" => { tmpl_dispatch_arm_placeholder() }",
                dispatch_arms.join("\n"),
            ),
        ],
    );

    format!("{header}{body}")
}

/// Port of `rust/project/registry.rb#emit_reference_table`.
pub fn emit_reference_table(aggregates: &[AggregateEntry]) -> String {
    let rows: Vec<String> = aggregates
        .iter()
        .map(|a| {
            let qualified = format!("{}::{}", a.domain_name, a.name);
            format!(
                "    ({}, {}),",
                naming::ruby_inspect_string(&qualified),
                reference_specs::emit_reference_specs_literal(&a.reference_specs)
            )
        })
        .collect();

    format!(
        "pub static REFERENCE_TABLE: crate::kernel::ReferenceTable = &[\n{}\n];\n",
        rows.join("\n")
    )
}

/// Port of `rust/project/registry.rb#emit_reference_lookup`.
pub fn emit_reference_lookup(aggregates: &[AggregateEntry]) -> String {
    let arms: Vec<String> = aggregates
        .iter()
        .map(|a| {
            let prefix = format!("{}::{}", a.domain_name, a.name);
            format!(
                "if target == {} {{\n    return self.{}.find(id).map(|r| Box::new(r) as Box<dyn crate::kernel::Fielded>);\n}}",
                naming::ruby_inspect_string(&prefix),
                a.module_name
            )
        })
        .collect();

    format!(
        "{}\nimpl crate::kernel::ReferenceLookup for Store {{\n    fn find_fielded(&self, target: &str, id: &str) -> Option<Box<dyn crate::kernel::Fielded>> {{\n{}\n        None\n    }}\n}}\n",
        emit_reference_table(aggregates),
        arms.join("\n")
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn generated_router_separates_routes_and_supports_compound_create_facts() {
        let aggregate = AggregateEntry {
            name: "SafeDepositBox".to_string(),
            module_name: "safedepositbox".to_string(),
            record: "SafeDepositBox".to_string(),
            commands: vec![
                CommandEntry {
                    verb: "Banking::SafeDepositBox.Rent".to_string(),
                    name: "Rent".to_string(),
                    fn_name: "rent".to_string(),
                    args_struct: "RentArgs".to_string(),
                    creates: true,
                    identity_extra_params: vec![
                        "branch_code".to_string(),
                        "box_number".to_string(),
                    ],
                    reference_checks: Vec::new(),
                    tenant_boundary_checks: Vec::new(),
                    reference_specs: Vec::new(),
                    attributes: Vec::new(),
                    invariant_check_lines: Vec::new(),
                    role: None,
                },
                CommandEntry {
                    verb: "Banking::SafeDepositBox.Close".to_string(),
                    name: "Close".to_string(),
                    fn_name: "close".to_string(),
                    args_struct: "CloseArgs".to_string(),
                    creates: false,
                    identity_extra_params: Vec::new(),
                    reference_checks: Vec::new(),
                    tenant_boundary_checks: Vec::new(),
                    reference_specs: Vec::new(),
                    attributes: Vec::new(),
                    invariant_check_lines: Vec::new(),
                    role: None,
                },
            ],
            entity_commands: vec![EntityCommandEntry {
                verb: "Banking::SafeDepositBox.Visit.Annotate".to_string(),
                name: "Annotate".to_string(),
                entity_record: "Visit".to_string(),
                fn_name: "visit_annotate".to_string(),
                args_struct: "VisitAnnotateArgs".to_string(),
                reference_checks: Vec::new(),
                reference_specs: Vec::new(),
                attributes: Vec::new(),
                invariant_check_lines: Vec::new(),
                role: None,
                entity_name: "Visit".to_string(),
                entity_identity_reading: "date, sequence".to_string(),
            }],
            nested_entity_commands: Vec::new(),
            ports: vec![PortEntry {
                verb: "Banking::SafeDepositBox.PaymentGateway.Receive".to_string(),
                name: "Receive".to_string(),
                fn_name: "paymentgateway_receive".to_string(),
                args_struct: "PaymentGatewayReceiveArgs".to_string(),
                reference_checks: Vec::new(),
                legacy_receiver_field: None,
                to_receiver_field: None,
            }],
            chapter_mod: "banking".to_string(),
            domain_name: "Banking".to_string(),
            reference_specs: Vec::new(),
            identified_by: vec!["branch_code".to_string(), "box_number".to_string()],
            entities: Vec::new(),
        };

        let generated = emit_registry(&Exemplar::load(), &[aggregate]);

        assert!(generated.contains("CommandInvocation::from_json(args_json)?"));
        assert!(generated.contains("let branch_code = facts_json.dig(\"branch_code\")"));
        assert!(generated.contains("let box_number = facts_json.dig(\"box_number\")"));
        // `from_json` is reached through the `normalize_args` hook; route depth leads the body and
        // identity resolves after every gate.
        assert!(generated.contains("crate::kernel::decode_aggregate_arguments(facts_json, &crate::kernel::ArgumentGates {"));
        assert!(generated.contains("decode_arguments: &crate::generated::banking::safedepositbox::RentArgs::decode_arguments"));
        assert!(generated.contains("refuse_unknown_arguments: &crate::generated::banking::safedepositbox::RentArgs::refuse_unknown_arguments"));
        assert!(generated.contains("refuse_absent_arguments: &crate::generated::banking::safedepositbox::RentArgs::refuse_absent_arguments"));
        assert!(generated.contains("RentArgs::from_json(v)?"));
        assert!(generated.contains("if let Some(route) = route { route.require_depth(0)?; }"));
        assert!(generated.contains("Some(route) => route.aggregate().to_string()"));
        assert!(generated.contains("if let Some(route) = route { route.require_depth(1)?; }"));
        assert!(generated.contains("crate::kernel::decode_entity_arguments(facts_json, &crate::kernel::ArgumentGates {"));
        assert!(generated.contains("let element_id = route.entities()[0].clone()"));
        assert!(generated.contains("VisitAnnotateArgs::from_json(v)?"));
        assert!(!generated.contains("RentArgs::from_json(facts_json)?"));
        assert!(generated.contains("Json::overlay(facts_json, &args.to_json())"));
        assert!(!generated.contains("VisitAnnotateArgs::from_json(args_json)?"));
        assert!(generated
            .contains("let (id, port_facts) = invocation.split_aggregate_receiver(None, None)?;"));
        assert!(generated.contains("store.safedepositbox.find(&id)"));
        assert!(generated.contains("PaymentGatewayReceiveArgs::from_json(facts_json)?"));
        assert!(generated.contains("dispatch_operation_paymentgateway_receive(&id, args)"));
    }

    // Pins that the generated code branches on `invocation.explicit_with()` at runtime: both the
    // gates-first and route-depth-first orders are present, neither hard-coded.
    #[test]
    fn explicit_with_gates_precheck_ordering_for_an_acting_command() {
        let aggregate = AggregateEntry {
            name: "Hangar".to_string(),
            module_name: "hangar".to_string(),
            record: "Hangar".to_string(),
            commands: vec![CommandEntry {
                verb: "Fixture::Hangar.Prioritize".to_string(),
                name: "Prioritize".to_string(),
                fn_name: "prioritize".to_string(),
                args_struct: "PrioritizeArgs".to_string(),
                creates: false,
                identity_extra_params: Vec::new(),
                reference_checks: Vec::new(),
                tenant_boundary_checks: Vec::new(),
                reference_specs: Vec::new(),
                attributes: vec!["priority".to_string()],
                invariant_check_lines: Vec::new(),
                role: None,
            }],
            entity_commands: Vec::new(),
            nested_entity_commands: Vec::new(),
            ports: Vec::new(),
            chapter_mod: "fixture".to_string(),
            domain_name: "Fixture".to_string(),
            reference_specs: Vec::new(),
            identified_by: vec!["code".to_string()],
            entities: Vec::new(),
        };

        let generated = emit_registry(&Exemplar::load(), &[aggregate]);

        assert!(generated.contains("let args = if invocation.explicit_with() { let args = crate::kernel::decode_aggregate_arguments(facts_json, &crate::kernel::ArgumentGates {"));
        assert!(generated.contains("if let Some(route) = route { route.require_depth(0)?; } args } else { if let Some(route) = route { route.require_depth(0)?; } crate::kernel::decode_aggregate_arguments(facts_json, &crate::kernel::ArgumentGates {"));
        assert!(generated.contains("Some(route) => route.aggregate().to_string()"));
    }

    // Pins that a failing `extract_id` in an acting command refuses NotFound
    // (`acting_no_identity`), not TypeMismatch, with wording rendered at codegen time.
    #[test]
    fn acting_command_id_resolution_failure_refuses_not_found_not_type_mismatch() {
        let aggregate = AggregateEntry {
            name: "SafeDepositBox".to_string(),
            module_name: "safedepositbox".to_string(),
            record: "SafeDepositBox".to_string(),
            commands: vec![CommandEntry {
                verb: "Banking::SafeDepositBox.Close".to_string(),
                name: "Close".to_string(),
                fn_name: "close".to_string(),
                args_struct: "CloseArgs".to_string(),
                creates: false,
                identity_extra_params: Vec::new(),
                reference_checks: Vec::new(),
                tenant_boundary_checks: Vec::new(),
                reference_specs: Vec::new(),
                attributes: Vec::new(),
                invariant_check_lines: Vec::new(),
                role: None,
            }],
            entity_commands: Vec::new(),
            nested_entity_commands: Vec::new(),
            ports: Vec::new(),
            chapter_mod: "banking".to_string(),
            domain_name: "Banking".to_string(),
            reference_specs: Vec::new(),
            identified_by: vec!["branch_code.value".to_string(), "box_number.value".to_string()],
            entities: Vec::new(),
        };

        let generated = emit_registry(&Exemplar::load(), &[aggregate]);

        // The raw `extract_id(facts_json)?` must not appear in an acting command's id_line ...
        assert!(!generated.contains("SafeDepositBox::extract_id(facts_json)?,"));
        // ... replaced by a wrapper converting its failure into NotFound/acting_no_identity.
        assert!(generated.contains(
            "SafeDepositBox::extract_id(facts_json).map_err(|_| crate::kernel::Refusal::NotFound(crate::kernel::refusal_wording::NotFoundActingNoIdentityArgs { command: \"Close\", aggregate: \"SafeDepositBox\", identity: \"branch_code.value, box_number.value\" }.render_args()))?,"
        ));
    }
}
