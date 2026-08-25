//! Port of `rust/project/registry.rb` — the JSON command router. Read
//! that file's own header comments in full; this mirrors its algorithm
//! directly, function for function. The plain data shapes below
//! (`ReferenceCheck`/`CommandEntry`/`EntityCommandEntry`/`PortEntry`/
//! `AggregateEntry`) mirror the Hash shapes `domain_generator.rb` itself
//! accumulates while walking the IR (that file's own header spells out
//! the exact keys).

use crate::exemplar::Exemplar;
use crate::naming;
use crate::reference_specs::{self, ReferenceSpec};

#[derive(Clone)]
pub struct ReferenceCheck {
    pub field: String,
    pub optional: bool,
    pub target_mod: String,
    pub target_name: String,
    pub heads: String,
}

pub struct CommandEntry {
    pub verb: String,
    pub name: String,
    pub fn_name: String,
    pub args_struct: String,
    pub creates: bool,
    pub identity_extra_params: Vec<String>,
    pub reference_checks: Vec<ReferenceCheck>,
    /// This command's OWN reference-typed attributes — `command_deref`'s
    /// own specs (`reference_specs.rb`'s own header).
    pub reference_specs: Vec<ReferenceSpec>,
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
    pub role: Option<String>,
    /// `entity_name:`/`entity_identity_reading:` — carried in
    /// `domain_generator.rb`'s own `entity_commands` hash (its own
    /// comment: for `entity_element_missing`'s `{entity}`/`{identity}`
    /// wording, codegen-time-static) but NOT actually read anywhere in
    /// `registry.rb`'s own `emit_registry` — `commands.rb#emit_entity_
    /// command` already computes the identical reading itself, inline,
    /// off the `entity` node it's handed directly. Kept here for shape
    /// parity with Ruby's own hash, not because anything in this crate's
    /// ported scope consumes them.
    pub entity_name: String,
    pub entity_identity_reading: String,
}

pub struct PortEntry {
    pub verb: String,
    pub name: String,
    pub fn_name: String,
    pub args_struct: String,
    pub reference_checks: Vec<ReferenceCheck>,
    /// Compatibility-only self-reference field from older port IR. New
    /// operations receive their owner solely through the routing envelope.
    pub legacy_receiver_field: Option<String>,
    /// `to:`-declared operations' own receiver field — a plain, real
    /// attribute (never stripped from the payload the way
    /// legacy_receiver_field is), named for the owning aggregate's own
    /// identified_by field. See domain_generator.rs's own comment on
    /// why this stays a separate field rather than folding into
    /// legacy_receiver_field.
    pub to_receiver_field: Option<String>,
}

pub struct AggregateEntry {
    pub name: String,
    pub module_name: String,
    pub record: String,
    pub commands: Vec<CommandEntry>,
    pub entity_commands: Vec<EntityCommandEntry>,
    pub ports: Vec<PortEntry>,
    pub chapter_mod: String,
    pub domain_name: String,
    /// This AGGREGATE's own reference-typed attributes — `owner_deref`'s
    /// own specs, and the domain-wide `REFERENCE_TABLE`'s own row for
    /// this aggregate (`reference_specs.rb`'s own header).
    pub reference_specs: Vec<ReferenceSpec>,
    /// THIS AGGREGATE'S OWN DECLARED IDENTITY PATHS, carried through
    /// verbatim — `reactions.rs`'s own `emit_identity_head_table` reads
    /// the single-component case (the only shape it resolves).
    pub identified_by: Vec<String>,
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

pub fn emit_reference_check(exemplar: &Exemplar, check: &ReferenceCheck) -> String {
    let ident = naming::rust_ident_field(&check.field);
    if check.optional {
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
                "if aggregate == {} {{\n    return Some(self.{}.entries().map(|(id, record)| (id.clone(), record.to_json())).collect());\n}}",
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

            let dispatch_call = format!(
                "{mod_path}::dispatch_{}(&mut store.{}, {}args, mutations, owner_deref, command_deref)",
                c.fn_name,
                a.module_name,
                if c.creates { extra_pass } else { "&id, ".to_string() }
            );
            let id_line = if c.creates {
                String::new()
            } else {
                format!(
                    "let id = match route {{ Some(route) => {{ route.require_depth(0)?; route.aggregate().to_string() }}, None => {mod_path}::{}::extract_id(facts_json)?, }};",
                    a.record
                )
            };
            let role_line = emit_role_check(exemplar, c.role.as_deref(), &c.name);
            let reference_lines: Vec<String> = c
                .reference_checks
                .iter()
                .map(|check| emit_reference_check(exemplar, check))
                .collect();

            // `owner_deref`/`command_deref` — see `reference_lookup.rs`'s
            // own header and `rust/project/registry.rb`'s identical
            // comment: resolved HERE, before the `&mut store.<mod>`
            // borrow below, since it needs `store` as a whole.
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
            if !id_line.is_empty() {
                body.push(id_line);
            }
            body.extend(extra_lines);
            body.push(format!(
                "let args = {mod_path}::{}::from_json(facts_json)?;",
                c.args_struct
            ));
            if let Some(rl) = role_line {
                if !rl.is_empty() {
                    body.push(rl);
                }
            }
            body.extend(reference_lines.into_iter().filter(|l| !l.is_empty()));
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
            let role_line = emit_role_check(exemplar, c.role.as_deref(), &c.name);
            let reference_lines: Vec<String> = c
                .reference_checks
                .iter()
                .map(|check| emit_reference_check(exemplar, check))
                .collect();
            let dispatch_call = format!(
                "{mod_path}::dispatch_entity_{}(&mut store.{}, &parent_id, &element_id, &element_wants, args, mutations, owner_deref, command_deref).map(|(_, events)| stamp_payload(events, &payload))",
                c.fn_name, a.module_name
            );

            let mut body: Vec<String> = vec![
                "let invocation = crate::kernel::CommandInvocation::from_json(args_json)?;".to_string(),
                "let route = invocation.route();".to_string(),
                "let facts_json = invocation.facts();".to_string(),
                format!(
                    "let (parent_id, element_id, element_wants) = match route {{ Some(route) => {{ route.require_depth(1)?; let element_id = route.entities()[0].clone(); (route.aggregate().to_string(), element_id.clone(), element_id) }}, None => {{ let parent_id = {mod_path}::{}::extract_id(facts_json)?; let element_id = {mod_path}::{}::extract_id(facts_json)?; let element_wants = {mod_path}::{}::extract_wants(facts_json); (parent_id, element_id, element_wants) }}, }};",
                    a.record, c.entity_record, c.entity_record
                ),
                format!("let args = {mod_path}::{}::from_json(facts_json)?;", c.args_struct),
            ];
            if let Some(rl) = role_line {
                body.push(rl);
            }
            body.extend(reference_lines);
            // `owner_deref` is always empty for an entity command — see
            // `rust/project/registry.rb`'s own header on the real,
            // documented gap (no entity in this corpus declares its own
            // `reference_to`). `command_deref` covers the entity
            // command's own reference-typed arguments, PLUS — merged in
            // exactly like Ruby's own `parent:` tier — the PARENT
            // aggregate's own dereferenced state under one `"parent"` key.
            body.push(
                "let owner_deref: Vec<(&'static str, crate::kernel::DerefNode)> = Vec::new();"
                    .to_string(),
            );
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
                    reference_specs: Vec::new(),
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
                    reference_specs: Vec::new(),
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
                role: None,
                entity_name: "Visit".to_string(),
                entity_identity_reading: "date, sequence".to_string(),
            }],
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
        };

        let generated = emit_registry(&Exemplar::load(), &[aggregate]);

        assert!(generated.contains("CommandInvocation::from_json(args_json)?"));
        assert!(generated.contains("let branch_code = facts_json.dig(\"branch_code\")"));
        assert!(generated.contains("let box_number = facts_json.dig(\"box_number\")"));
        assert!(generated.contains("RentArgs::from_json(facts_json)?"));
        assert!(generated.contains("route.require_depth(0)?; route.aggregate().to_string()"));
        assert!(generated.contains("route.require_depth(1)?"));
        assert!(generated.contains("let element_id = route.entities()[0].clone()"));
        assert!(generated.contains("VisitAnnotateArgs::from_json(facts_json)?"));
        assert!(generated.contains("Json::overlay(facts_json, &args.to_json())"));
        assert!(!generated.contains("VisitAnnotateArgs::from_json(args_json)?"));
        assert!(generated
            .contains("let (id, port_facts) = invocation.split_aggregate_receiver(None, None)?;"));
        assert!(generated.contains("store.safedepositbox.find(&id)"));
        assert!(generated.contains("PaymentGatewayReceiveArgs::from_json(facts_json)?"));
        assert!(generated.contains("dispatch_operation_paymentgateway_receive(&id, args)"));
    }
}
