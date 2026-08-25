//! Port of `rust/project/domain_generator.rb`'s `DomainGenerator.call` —
//! the FULL per-aggregate `.rs` file (value objects, entities incl. their
//! own commands, the record, aggregate-level commands, port operations)
//! plus `registry.rs`. Read that file's own header comments in full.
//!
//! Deliberately NOT reused from `prelude.rs`: the real Ruby file
//! INTERLEAVES entity commands (`entity[:commands].each`) inside the
//! `aggregate[:entities].each` loop, BEFORE `emit_record` — a real
//! aggregate with entity commands (banking's `SafeDepositBox`/`ATMCard`)
//! would get the WRONG full-file shape from `prelude.rs`'s own entities
//! loop, which only ever emitted entity struct/codec/extract_id, never
//! entity commands (a real, confirmed gap in the prior stage's own
//! "prelude" scope — see this module's own report). This file
//! reimplements the whole per-aggregate walk from scratch instead, so it
//! is correct for any aggregate, not just ones without entity commands.
//!
//! NOT ported here: `metadata.rs` (embeds `ir.json` as a Rust string
//! constant via Ruby's own `.inspect` — needs a JSON pretty-printer this
//! crate does not have, see `json.rs`'s own header on why: this crate
//! only ever READS `ir.json`, never re-emits it), `ir.json` itself (the
//! same reason), and `manifest.json` (bookkeeping only, no bearing on
//! whether the generated `.rs` source is correct) — all three are named,
//! honest gaps in the stage report, not silently dropped.

use crate::exemplar::Exemplar;
use crate::json::Json;
use crate::registry::{
    AggregateEntry, CommandEntry, EntityCommandEntry, PortEntry, ReferenceCheck,
};
use crate::{commands, json_codec, mutations, ports, queries, reactions, read_models, types};
use std::collections::HashMap;

fn puts_str(out: &mut String, s: &str) {
    out.push_str(s);
    if !s.ends_with('\n') {
        out.push('\n');
    }
}

fn puts_blank(out: &mut String) {
    out.push('\n');
}

fn lifecycle_extra_field(node: &Json) -> Vec<(String, String)> {
    match node.get("lifecycle") {
        None => vec![],
        Some(lifecycle) => {
            let field = lifecycle.get("field").and_then(Json::as_str).unwrap_or("");
            let ident = crate::naming::rust_ident_field(field);
            vec![(
                crate::naming::rust_field(field),
                format!("crate::kernel::Json::Str(self.{ident}.clone())"),
            )]
        }
    }
}

pub struct GeneratedFile {
    pub name: String,
    pub content: String,
}

pub struct GeneratedDomain {
    /// One entry per NOT-skipped aggregate: `<name_downcase>.rs`.
    pub aggregate_files: Vec<GeneratedFile>,
    pub registry_rs: String,
    pub mod_rs: String,
    /// Returned for a multi-chapter caller the same way
    /// `domain_generator.rb#call`'s own return value is — used by
    /// `main.rs::run_full` (STAGE 8) to build a TARGET domain's own
    /// `merged.rs`, unioning this chapter's own aggregates/queries/read
    /// models with every attached framework chapter's own, exactly the
    /// way `bin/project_rust`'s Ruby orchestration already does with
    /// `RustProjection::DomainGenerator.call`'s own return Hash
    /// (`:aggregates`/`:queries`/`:read_models`).
    pub registry_aggregates: Vec<AggregateEntry>,
    pub query_defs: Vec<crate::queries::QueryDef>,
    pub read_model_defs: Vec<crate::read_models::ReadModelDef>,
}

fn reference_checks(
    command: &Json,
    aggregates_by_name: &HashMap<String, &Json>,
    unsupported_names: &[String],
) -> Vec<ReferenceCheck> {
    let attrs = command.get("attributes").map(Json::each).unwrap_or(&[]);
    attrs
        .iter()
        .filter_map(|attr| {
            let target_name = crate::naming::reference_target(crate::attr::type_name(attr))?;
            let target = aggregates_by_name.get(target_name)?;
            if unsupported_names.iter().any(|n| n == target_name) {
                return None;
            }
            let identified_by = target.get("identified_by").map(Json::each).unwrap_or(&[]);
            let heads = identified_by
                .iter()
                .map(|p| p.to_s().split('.').next().unwrap_or("").to_string())
                .collect::<Vec<_>>()
                .join(", ");
            Some(ReferenceCheck {
                field: crate::attr::name(attr).to_string(),
                optional: crate::attr::optional(attr),
                target_mod: target
                    .get("name")
                    .and_then(Json::as_str)
                    .unwrap_or("")
                    .to_lowercase(),
                target_name: target
                    .get("name")
                    .and_then(Json::as_str)
                    .unwrap_or("")
                    .to_string(),
                heads,
            })
        })
        .collect()
}

pub fn generate(
    exemplar: &Exemplar,
    ir: &Json,
    source_label: &str,
    mod_name: &str,
) -> GeneratedDomain {
    let domain_name = ir.get("name").and_then(Json::as_str).unwrap_or("");
    let all_aggregates = ir.get("aggregates").map(Json::each).unwrap_or(&[]);
    let aggregates_by_name: HashMap<String, &Json> = all_aggregates
        .iter()
        .map(|a| {
            (
                a.get("name")
                    .and_then(Json::as_str)
                    .unwrap_or("")
                    .to_string(),
                a,
            )
        })
        .collect();

    let unsupported_names: Vec<String> = all_aggregates
        .iter()
        .filter(|a| {
            let vos = a.get("value_objects").map(Json::each).unwrap_or(&[]);
            let vo_by_name: HashMap<String, &Json> = vos
                .iter()
                .map(|vo| {
                    (
                        vo.get("name")
                            .and_then(Json::as_str)
                            .unwrap_or("")
                            .to_string(),
                        vo,
                    )
                })
                .collect();
            !types::unsupported_attribute_types(a, &vo_by_name).is_empty()
        })
        .map(|a| {
            a.get("name")
                .and_then(Json::as_str)
                .unwrap_or("")
                .to_string()
        })
        .collect();

    let mut aggregate_files: Vec<GeneratedFile> = Vec::new();
    let mut registry_aggregates: Vec<AggregateEntry> = Vec::new();
    let process_managers: Vec<Json> = ir
        .get("process_managers")
        .map(Json::each)
        .unwrap_or(&[])
        .to_vec();

    // WHICH AGGREGATE OWNS EACH VALUE OBJECT, across this WHOLE domain — a
    // COMMAND's own attribute can name ANY value object the domain
    // declares, not just one its own owner also happens to declare
    // (`Banking::SafeDepositBox.Rent`'s own `attribute :customer,
    // CustomerNumber` — `CustomerNumber` is `Customer`'s own, never
    // `SafeDepositBox`'s). See `bridging.rs`'s own
    // `cross_aggregate_vo_imports` header. Last-writer-wins per name,
    // matching Ruby's `each_with_object`.
    let mut domain_value_object_owner: HashMap<String, String> = HashMap::new();
    for a in all_aggregates {
        let owner = a.get("name").and_then(Json::as_str).unwrap_or("").to_string();
        for vo in a.get("value_objects").map(Json::each).unwrap_or(&[]) {
            domain_value_object_owner.insert(
                vo.get("name").and_then(Json::as_str).unwrap_or("").to_string(),
                owner.clone(),
            );
        }
    }
    // THE VALUE OBJECTS THEMSELVES, same domain-wide reach — `bridging.rs`'s
    // own `bridgeable_value_types`/`value_rhs` need the actual DEFINITION
    // (not just which aggregate owns it) to bridge a cross-aggregate command
    // argument's type into its target field. Merged into each aggregate's
    // own LOCAL map below with the local map winning any name collision.
    let mut domain_value_objects_by_name: HashMap<String, &Json> = HashMap::new();
    for a in all_aggregates {
        for vo in a.get("value_objects").map(Json::each).unwrap_or(&[]) {
            domain_value_objects_by_name.insert(vo.get("name").and_then(Json::as_str).unwrap_or("").to_string(), vo);
        }
    }

    for aggregate in all_aggregates {
        let agg_name = aggregate.get("name").and_then(Json::as_str).unwrap_or("");
        if unsupported_names.iter().any(|n| n == agg_name) {
            continue;
        }

        let value_objects = aggregate
            .get("value_objects")
            .map(Json::each)
            .unwrap_or(&[]);
        let mut value_objects_by_name: HashMap<String, &Json> = domain_value_objects_by_name.clone();
        value_objects_by_name.extend(value_objects.iter().map(|vo| {
            (
                vo.get("name")
                    .and_then(Json::as_str)
                    .unwrap_or("")
                    .to_string(),
                vo,
            )
        }));

        let record_name = crate::naming::rust_ident(agg_name);
        let can_route = json_codec::extract_id_supported(aggregate);

        let mut out = String::new();
        puts_str(
            &mut out,
            &format!("// GENERATED by bin/project_rust from {source_label}'s canonical IR."),
        );
        puts_str(
            &mut out,
            "// Do not hand-edit — re-run bin/project_rust instead.",
        );
        puts_str(&mut out, "#![allow(dead_code, unused_variables)]");
        puts_str(&mut out, "use crate::kernel::Expr;");
        for line in crate::bridging::cross_aggregate_vo_imports(aggregate, &domain_value_object_owner, mod_name) {
            puts_str(&mut out, &line);
        }
        puts_blank(&mut out);

        for vo in value_objects {
            puts_str(
                &mut out,
                &types::emit_value_object(
                    exemplar,
                    vo,
                    &value_objects_by_name,
                    &aggregates_by_name,
                ),
            );
            puts_blank(&mut out);
            let closed_set = vo.get("closed_set").map(Json::as_bool).unwrap_or(false);
            let attrs = vo.get("attributes").map(Json::each).unwrap_or(&[]);
            if closed_set && attrs.len() == 1 {
                puts_str(&mut out, &json_codec::emit_closed_set_codec(exemplar, vo));
            } else if closed_set {
                puts_str(
                    &mut out,
                    &json_codec::emit_closed_set_table_codec(exemplar, vo),
                );
            } else {
                let name =
                    crate::naming::rust_ident(vo.get("name").and_then(Json::as_str).unwrap_or(""));
                puts_str(
                    &mut out,
                    &json_codec::emit_to_json_flat(exemplar, &name, attrs, &value_objects_by_name, false, &[], None),
                );
                puts_blank(&mut out);
                // `Some(&[])` — mirrors the Ruby generator's own fix
                // (rust/project/domain_generator.rb): a value object gets
                // the same unknown-key refusal an aggregate command's own
                // args struct already gets below, just with no extra
                // allowed keys beyond its own declared attributes. Without
                // this, a mistyped nested VO field (e.g. `{"value": N}`
                // for a VO that declares `count`) silently fell through to
                // any `default:` the real field carries, with zero
                // refusal — found live dispatching a real command through
                // the compiled binary.
                let empty_allowlist: [String; 0] = [];
                puts_str(
                    &mut out,
                    &json_codec::emit_from_json_flat(
                        exemplar,
                        &name,
                        attrs,
                        &value_objects_by_name,
                        Some(&empty_allowlist),
                        None,
                    ),
                );
            }
            puts_blank(&mut out);
        }

        let mut entity_commands: Vec<EntityCommandEntry> = Vec::new();

        for entity in aggregate.get("entities").map(Json::each).unwrap_or(&[]) {
            puts_str(
                &mut out,
                &types::emit_entity(exemplar, entity, &value_objects_by_name),
            );
            puts_blank(&mut out);
            let entity_name_ident =
                crate::naming::rust_ident(entity.get("name").and_then(Json::as_str).unwrap_or(""));
            let entity_attrs = entity.get("attributes").map(Json::each).unwrap_or(&[]);
            let extra = lifecycle_extra_field(entity);
            puts_str(
                &mut out,
                &json_codec::emit_to_json_flat(
                    exemplar,
                    &entity_name_ident,
                    entity_attrs,
                    &value_objects_by_name,
                    false,
                    &extra,
                    None,
                ),
            );
            puts_blank(&mut out);
            puts_str(
                &mut out,
                &json_codec::emit_from_json_state(
                    exemplar,
                    &entity_name_ident,
                    entity_attrs,
                    &value_objects_by_name,
                    false,
                    &extra,
                    None,
                ),
            );
            puts_blank(&mut out);

            // S17, ADR 0026 — AN ENTITY NESTED INSIDE THIS ONE
            // (`ProcessManager.Handler.Dispatch`). Struct + JSON codec
            // only, mirroring rust/project/domain_generator.rb's own
            // identical fix exactly — making a doubly-nested entity's
            // OWN commands (`Dispatch.Bind`) reachable through
            // kernel::cli.rs's JSON router is a separate, deeper
            // question the router/dispatch table aren't built for yet
            // (one level of Aggregate.Entity.Command, not two), so
            // those commands are simply never added to `entity_commands`
            // below — real functions never get emitted for them here at
            // all, unlike the Ruby generator's own manifest-tracked
            // skip; this tool has no manifest to track it in.
            for nested in entity.get("entities").map(Json::each).unwrap_or(&[]) {
                puts_str(
                    &mut out,
                    &types::emit_entity(exemplar, nested, &value_objects_by_name),
                );
                puts_blank(&mut out);
                let nested_name_ident = crate::naming::rust_ident(
                    nested.get("name").and_then(Json::as_str).unwrap_or(""),
                );
                let nested_attrs = nested.get("attributes").map(Json::each).unwrap_or(&[]);
                let nested_extra = lifecycle_extra_field(nested);
                puts_str(
                    &mut out,
                    &json_codec::emit_to_json_flat(
                        exemplar,
                        &nested_name_ident,
                        nested_attrs,
                        &value_objects_by_name,
                        false,
                        &nested_extra,
                        None,
                    ),
                );
                puts_blank(&mut out);
                puts_str(
                    &mut out,
                    &json_codec::emit_from_json_state(
                        exemplar,
                        &nested_name_ident,
                        nested_attrs,
                        &value_objects_by_name,
                        false,
                        &nested_extra,
                        None,
                    ),
                );
                puts_blank(&mut out);
            }

            let entity_can_route = json_codec::extract_id_supported(entity);
            if entity_can_route {
                puts_str(&mut out, &json_codec::emit_extract_id(exemplar, entity));
                puts_blank(&mut out);
                puts_str(&mut out, &json_codec::emit_extract_wants(exemplar, entity));
                puts_blank(&mut out);
                puts_str(&mut out, &json_codec::emit_self_identity(exemplar, entity));
                puts_blank(&mut out);
            }

            for command in entity.get("commands").map(Json::each).unwrap_or(&[]) {
                let reason =
                    commands::entity_command_skip_reason(command, entity, &value_objects_by_name);
                if reason.is_some() {
                    continue;
                }

                puts_str(
                    &mut out,
                    &commands::emit_entity_command(
                        exemplar,
                        command,
                        entity,
                        aggregate,
                        domain_name,
                        &value_objects_by_name,
                        &aggregates_by_name,
                    ),
                );
                puts_blank(&mut out);

                if !entity_can_route {
                    continue;
                }

                let entity_command_name = command.get("name").and_then(Json::as_str).unwrap_or("");
                let identified_by = entity.get("identified_by").map(Json::each).unwrap_or(&[]);
                entity_commands.push(EntityCommandEntry {
                    verb: format!(
                        "{domain_name}::{agg_name}.{entity_name_ident}.{entity_command_name}",
                        entity_name_ident = entity.get("name").and_then(Json::as_str).unwrap_or("")
                    ),
                    name: entity_command_name.to_string(),
                    entity_record: entity_name_ident.clone(),
                    fn_name: format!(
                        "{}_{}",
                        entity
                            .get("name")
                            .and_then(Json::as_str)
                            .unwrap_or("")
                            .to_lowercase(),
                        crate::naming::dispatch_fn_name(&crate::naming::rust_ident(
                            entity_command_name
                        ))
                    ),
                    args_struct: format!(
                        "{entity_name_ident}{}Args",
                        crate::naming::rust_ident(entity_command_name)
                    ),
                    reference_checks: reference_checks(
                        command,
                        &aggregates_by_name,
                        &unsupported_names,
                    ),
                    reference_specs: crate::reference_specs::reference_specs(
                        domain_name,
                        command.get("attributes").map(Json::each).unwrap_or(&[]),
                    ),
                    role: command.get("role").map(Json::to_s),
                    entity_name: entity
                        .get("name")
                        .and_then(Json::as_str)
                        .unwrap_or("")
                        .to_string(),
                    entity_identity_reading: identified_by
                        .iter()
                        .map(Json::to_s)
                        .collect::<Vec<_>>()
                        .join(", "),
                });
            }
        }

        puts_str(
            &mut out,
            &types::emit_record(exemplar, aggregate, &value_objects_by_name),
        );
        puts_blank(&mut out);
        let record_attrs = aggregate.get("attributes").map(Json::each).unwrap_or(&[]);
        let extra = lifecycle_extra_field(aggregate);
        puts_str(
            &mut out,
            &json_codec::emit_to_json_flat(
                exemplar,
                &record_name,
                record_attrs,
                &value_objects_by_name,
                true,
                &extra,
                Some(aggregate),
            ),
        );
        puts_blank(&mut out);
        puts_str(
            &mut out,
            &json_codec::emit_from_json_state(
                exemplar,
                &record_name,
                record_attrs,
                &value_objects_by_name,
                true,
                &extra,
                Some(aggregate),
            ),
        );
        puts_blank(&mut out);
        puts_str(&mut out, &format!("impl crate::kernel::ToJson for {record_name} {{\n    fn to_json(&self) -> crate::kernel::Json {{\n        {record_name}::to_json(self)\n    }}\n}}\n"));
        puts_blank(&mut out);

        if can_route {
            puts_str(&mut out, &json_codec::emit_extract_id(exemplar, aggregate));
            puts_blank(&mut out);
        }

        let mut registry_commands: Vec<CommandEntry> = Vec::new();
        for command in aggregate.get("commands").map(Json::each).unwrap_or(&[]) {
            let reason = commands::command_skip_reason(command, aggregate, &value_objects_by_name);
            if reason.is_some() {
                continue;
            }

            puts_str(
                &mut out,
                &commands::emit_command(
                    exemplar,
                    command,
                    aggregate,
                    domain_name,
                    &value_objects_by_name,
                    &aggregates_by_name,
                ),
            );
            puts_blank(&mut out);

            let command_name = command.get("name").and_then(Json::as_str).unwrap_or("");
            let args_struct = format!("{}Args", crate::naming::rust_ident(command_name));
            let cmd_attrs = command.get("attributes").map(Json::each).unwrap_or(&[]);
            puts_str(
                &mut out,
                &json_codec::emit_to_json_flat(exemplar, &args_struct, cmd_attrs, &value_objects_by_name, false, &[], None),
            );
            puts_blank(&mut out);
            let allowlist =
                json_codec::command_argument_allowlist(aggregate, command, &process_managers);
            puts_str(
                &mut out,
                &json_codec::emit_from_json_flat(
                    exemplar,
                    &args_struct,
                    cmd_attrs,
                    &value_objects_by_name,
                    Some(&allowlist),
                    Some(command_name),
                ),
            );
            puts_blank(&mut out);

            let creates = crate::shared::creates_owner(aggregate, command, &value_objects_by_name);
            let identity = mutations::identity_components(aggregate, command);
            let identity_extra_params: Vec<String> = if creates {
                identity.iter().filter_map(|c| c.head.clone()).collect()
            } else {
                Vec::new()
            };

            if !creates && !can_route {
                continue;
            }

            registry_commands.push(CommandEntry {
                verb: format!("{domain_name}::{agg_name}.{command_name}"),
                name: command_name.to_string(),
                fn_name: crate::naming::dispatch_fn_name(&crate::naming::rust_ident(command_name)),
                args_struct,
                creates,
                identity_extra_params,
                reference_checks: reference_checks(
                    command,
                    &aggregates_by_name,
                    &unsupported_names,
                ),
                reference_specs: crate::reference_specs::reference_specs(domain_name, cmd_attrs),
                role: command.get("role").map(Json::to_s),
            });
        }

        let mut port_operations: Vec<PortEntry> = Vec::new();
        for port in aggregate.get("ports").map(Json::each).unwrap_or(&[]) {
            let port_name = port.get("name").and_then(Json::as_str).unwrap_or("");
            for operation in port.get("operations").map(Json::each).unwrap_or(&[]) {
                let reason =
                    ports::port_operation_skip_reason(operation, agg_name, &value_objects_by_name);
                if reason.is_some() {
                    continue;
                }

                puts_str(
                    &mut out,
                    &ports::emit_port_operation(
                        exemplar,
                        operation,
                        port_name,
                        agg_name,
                        domain_name,
                        &value_objects_by_name,
                        &aggregates_by_name,
                    ),
                );
                puts_blank(&mut out);

                let operation_name = operation.get("name").and_then(Json::as_str).unwrap_or("");
                let operation_attrs = operation.get("attributes").map(Json::each).unwrap_or(&[]);
                let legacy_receiver_field = operation_attrs
                    .iter()
                    .find(|attr| {
                        crate::naming::reference_target(crate::attr::type_name(attr))
                            == Some(agg_name)
                    })
                    .map(|attr| crate::attr::name(attr).to_string());
                // `to:`-DECLARED OPERATIONS — mirrors
                // Dispatcher#port_invocation's own second, additive
                // branch (lib/hecks/runtime/dispatcher.rb): no
                // Reference-typed attribute exists for these
                // (legacy_receiver_field is always None), so the
                // receiver instead comes from a PLAIN external-fact
                // attribute named for the owning aggregate's own
                // identified_by field. Kept as a genuinely separate
                // field from legacy_receiver_field, not folded into it
                // — the kernel side (split_aggregate_receiver) must NOT
                // strip this one out of the payload the way it strips a
                // legacy receiver, since it's a real declared fact, not
                // routing-only synthetic state.
                let to_receiver_field = if operation.get("to").and_then(Json::as_str) == Some(agg_name) {
                    // `.split('.').next()` — `identified_by` in the IR is
                    // identity_paths, not the plain declared name
                    // (lib/hecks/bluebook/aggregate.rb's own
                    // `emits_ir(identified_by: :identity_paths, ...)`) —
                    // for a value-object-typed identity this resolves to
                    // a dotted internal path ("reference.value"), not
                    // the flat field name ("reference") the operation's
                    // own plain attribute is actually named. Confirmed
                    // the hard way against the Ruby mirror
                    // (rust/project/domain_generator.rb) generating the
                    // wrong, ungrepped field first.
                    aggregate
                        .get("identified_by")
                        .map(Json::each)
                        .unwrap_or(&[])
                        .first()
                        .map(Json::to_s)
                        .and_then(|s| s.split('.').next().map(str::to_string))
                } else {
                    None
                };
                let operation_reference_checks =
                    reference_checks(operation, &aggregates_by_name, &unsupported_names)
                        .into_iter()
                        .filter(|check| check.target_name != agg_name)
                        .collect();
                port_operations.push(PortEntry {
                    verb: format!("{domain_name}::{agg_name}.{port_name}.{operation_name}"),
                    name: operation_name.to_string(),
                    fn_name: format!(
                        "{}_{}",
                        port_name.to_lowercase(),
                        crate::naming::dispatch_fn_name(&crate::naming::rust_ident(operation_name))
                    ),
                    args_struct: format!(
                        "{}{}Args",
                        crate::naming::rust_ident(port_name),
                        crate::naming::rust_ident(operation_name)
                    ),
                    reference_checks: operation_reference_checks,
                    legacy_receiver_field,
                    to_receiver_field,
                });
            }
        }

        aggregate_files.push(GeneratedFile {
            name: format!("{}.rs", agg_name.to_lowercase()),
            content: out,
        });

        registry_aggregates.push(AggregateEntry {
            name: agg_name.to_string(),
            module_name: agg_name.to_lowercase(),
            record: record_name,
            commands: registry_commands,
            entity_commands,
            ports: port_operations,
            chapter_mod: mod_name.to_string(),
            domain_name: domain_name.to_string(),
            reference_specs: crate::reference_specs::reference_specs(
                domain_name,
                aggregate.get("attributes").map(Json::each).unwrap_or(&[]),
            ),
            identified_by: aggregate.get("identified_by").map(Json::each).unwrap_or(&[]).iter().map(Json::to_s).collect(),
        });
    }

    // ── QUERIES.
    let mut query_defs: Vec<queries::QueryDef> = Vec::new();
    for aggregate in all_aggregates {
        let agg_name = aggregate.get("name").and_then(Json::as_str).unwrap_or("");
        let value_objects = aggregate
            .get("value_objects")
            .map(Json::each)
            .unwrap_or(&[]);
        let value_objects_by_name: HashMap<String, &Json> = value_objects
            .iter()
            .map(|vo| {
                (
                    vo.get("name")
                        .and_then(Json::as_str)
                        .unwrap_or("")
                        .to_string(),
                    vo,
                )
            })
            .collect();

        for query in aggregate.get("queries").map(Json::each).unwrap_or(&[]) {
            let reason = queries::query_skip_reason(query, aggregate, &value_objects_by_name);
            if reason.is_some() {
                continue;
            }

            let query_name = query.get("name").and_then(Json::as_str).unwrap_or("");
            query_defs.push(queries::QueryDef {
                verb: format!("{domain_name}::{agg_name}.{query_name}"),
                aggregate: format!("{domain_name}::{agg_name}"),
                conditions: queries::query_conditions(query),
                order_by: query.get("order_by").map(queries::emit_query_order_by),
                limit: query.get("limit").map(queries::emit_query_limit),
            });
        }
    }

    // ── READ MODELS.
    let mut read_model_defs: Vec<read_models::ReadModelDef> = Vec::new();
    for read_model in ir.get("read_models").map(Json::each).unwrap_or(&[]) {
        let reason = read_models::read_model_skip_reason(
            read_model,
            &aggregates_by_name,
            &unsupported_names,
        );
        if reason.is_some() {
            continue;
        }
        read_model_defs.push(read_models::read_model_def(
            domain_name,
            read_model,
            &aggregates_by_name,
        ));
    }

    let policies: Vec<Json> = ir.get("policies").map(Json::each).unwrap_or(&[]).to_vec();
    // The RAW aggregate JSON, not `registry_aggregates` — a fan-out's
    // addressing key is read off the target command's own declared
    // `references`/`attributes`, which `AggregateEntry` does not carry.
    let policy_aggregates: Vec<Json> = ir.get("aggregates").map(Json::each).unwrap_or(&[]).to_vec();

    let mut registry_rs = String::new();
    puts_str(
        &mut registry_rs,
        &crate::registry::emit_registry(exemplar, &registry_aggregates),
    );
    puts_blank(&mut registry_rs);
    puts_str(
        &mut registry_rs,
        &crate::registry::emit_reference_lookup(&registry_aggregates),
    );
    puts_blank(&mut registry_rs);
    puts_str(
        &mut registry_rs,
        &reactions::emit_policy_table(exemplar, domain_name, &policies, &policy_aggregates),
    );
    puts_blank(&mut registry_rs);
    puts_str(
        &mut registry_rs,
        &reactions::emit_cross_domain_policy_table(exemplar, domain_name, &policies),
    );
    puts_blank(&mut registry_rs);
    puts_str(
        &mut registry_rs,
        &reactions::emit_process_manager_table(exemplar, &process_managers),
    );
    puts_blank(&mut registry_rs);
    let generated_names: Vec<String> = registry_aggregates.iter().map(|a| a.name.clone()).collect();
    puts_str(
        &mut registry_rs,
        &reactions::emit_reference_key_table(
            exemplar,
            &[(domain_name.to_string(), generated_names)],
        ),
    );
    puts_blank(&mut registry_rs);
    puts_str(
        &mut registry_rs,
        &reactions::emit_creates_table(exemplar, &registry_aggregates),
    );
    puts_blank(&mut registry_rs);
    puts_str(
        &mut registry_rs,
        &reactions::emit_identity_head_table(exemplar, &registry_aggregates),
    );
    puts_blank(&mut registry_rs);
    puts_str(
        &mut registry_rs,
        &queries::emit_query_table(exemplar, &query_defs),
    );
    puts_blank(&mut registry_rs);
    puts_str(
        &mut registry_rs,
        &read_models::emit_read_model_table(exemplar, &read_model_defs),
    );

    let mut mod_rs = String::new();
    puts_str(
        &mut mod_rs,
        "// GENERATED by bin/project_rust — re-run it to refresh this list.",
    );
    puts_str(&mut mod_rs, "pub mod metadata;");
    puts_str(&mut mod_rs, "pub mod registry;");
    for a in &registry_aggregates {
        puts_str(&mut mod_rs, &format!("pub mod {};", a.name.to_lowercase()));
    }

    GeneratedDomain {
        aggregate_files,
        registry_rs,
        mod_rs,
        registry_aggregates,
        query_defs,
        read_model_defs,
    }
}
