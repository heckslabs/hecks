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
//! only ever READS `ir.json`, never re-emits it) and `ir.json` itself (the
//! same reason) — named, honest gaps, not silently dropped.
//!
//! `manifest.json` IS ported (`manifest.rs`): every `manifest_entry` call
//! site in the Ruby file has a `manifest.*` call at the matching decision
//! point below, with byte-identical reason text.

use crate::exemplar::Exemplar;
use crate::json::Json;
use crate::manifest::{ruby_inspect, Manifest};
use crate::registry::{
    AggregateEntry, CommandEntry, EntityCommandEntry, EntityIdentityEntry, NestedEntityCommandEntry, PortEntry,
    ReferenceCheck, TenantBoundaryCheck,
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
    /// `JSON.pretty_generate(manifest)` — the exact `manifest.json` bytes.
    pub manifest_json: String,
}

fn node_name(node: &Json) -> &str {
    node.get("name").and_then(Json::as_str).unwrap_or("")
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

/// Port of `rust/project/domain_generator.rb#state_reference_checks` —
/// see that method's own header for the full argument. `CommandRules::
/// References#resolve_state_references`' own case (references.rb): a
/// reference field redeclared on THIS command under a plain value object
/// (`attribute :member, Handle; sets :member` — `Referral.Reassign`'s
/// own shape, ADR 0037 Finding 5, reopened as QualityControl BUG#26),
/// checked against the AGGREGATE's own `Reference<X>` attribute of the
/// same name instead of the command's (non-reference) one, which
/// `reference_checks` above cannot see. A bare `sets :field` mutation
/// copies its source ARGUMENT's value straight into the aggregate's
/// field, unconditionally, so the settled value this needs is already
/// sitting in `args` before dispatch even runs — this reuses the exact
/// same pre-dispatch check shape `reference_checks` already emits, just
/// resolved against the aggregate's own attribute. Skips a source
/// argument that is ALREADY `Reference<X>`-typed (`Referral.Issue`'s own
/// `member`) — `reference_checks` above already covers that shape.
fn state_reference_checks(
    aggregate: &Json,
    command: &Json,
    aggregates_by_name: &HashMap<String, &Json>,
    unsupported_names: &[String],
    value_objects_by_name: &HashMap<String, &Json>,
) -> Vec<ReferenceCheck> {
    let agg_attrs = aggregate.get("attributes").map(Json::each).unwrap_or(&[]);
    let cmd_mutations = command.get("mutations").map(Json::each).unwrap_or(&[]);
    let cmd_attrs = command.get("attributes").map(Json::each).unwrap_or(&[]);

    agg_attrs
        .iter()
        .filter_map(|attr| {
            let target_name = crate::naming::reference_target(crate::attr::type_name(attr))?;
            // BUG#25/BUG#26 interaction — see `rust/project/domain_
            // generator.rb#state_reference_checks`'s own matching
            // comment: this function's own header already documents a
            // `has_many`/list relationship as "not covered,
            // deliberately," but nothing here enforced that until now —
            // a `has_many` field built a `check_reference` call against
            // `args.<field>.value`, a single-element accessor applied to
            // the whole `Vec`, which does not compile.
            if crate::attr::list(attr) {
                return None;
            }
            let attr_name = crate::attr::name(attr);

            let mutation = cmd_mutations.iter().find(|m| {
                m.get("op").map(Json::to_s).as_deref() == Some("set")
                    && m.get("target").map(Json::to_s).as_deref() == Some(attr_name)
                    && m.get("source").and_then(|s| s.get("kind")).map(Json::to_s).as_deref() == Some("argument")
            })?;

            let source_name = mutation.get("source").and_then(|s| s.get("name")).map(Json::to_s).unwrap_or_default();
            let source_attr = cmd_attrs.iter().find(|a| crate::attr::name(a) == source_name)?;
            if crate::naming::reference_target(crate::attr::type_name(source_attr)).is_some() {
                return None;
            }

            let accessor = state_reference_check_accessor(source_attr, value_objects_by_name)?;

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
                field: accessor,
                optional: crate::attr::optional(source_attr),
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

/// Port of `rust/project/domain_generator.rb#state_reference_check_accessor`
/// — see that method's own header for the full argument. `None` for a
/// multi-attribute value object, or an OPTIONAL single-attribute one
/// (`check_reference`'s optional-argument template assumes `Option<
/// String>`, not `Option<Struct>`) — both real, narrow, deliberately
/// uncovered gaps, matching ADR 0037 Finding 5's own precedent.
fn state_reference_check_accessor(source_attr: &Json, value_objects_by_name: &HashMap<String, &Json>) -> Option<String> {
    let name = crate::attr::name(source_attr);
    if crate::naming::effective_scalar_type(crate::attr::type_name(source_attr)).is_some() {
        return Some(name.to_string());
    }

    let vo = value_objects_by_name.get(crate::attr::type_name(source_attr))?;
    if crate::attr::optional(source_attr) {
        return None;
    }
    let vo_attrs = vo.get("attributes").map(Json::each).unwrap_or(&[]);
    if vo_attrs.len() != 1 {
        return None;
    }

    Some(format!("{name}.{}", crate::naming::rust_ident_field(crate::attr::name(&vo_attrs[0]))))
}

/// Port of `rust/project/domain_generator.rb#tenant_field_for` — an
/// aggregate's own tenant field is whichever field one of its OWN queries
/// names in `authorize policy, tenant: :field`. `None` for an aggregate
/// declaring no tenant-scoping query.
fn tenant_field_for(aggregate: &Json) -> Option<String> {
    aggregate.get("queries").map(Json::each).unwrap_or(&[]).iter().find_map(|q| {
        let tenant = q.get("authorization")?.get("tenant")?;
        if matches!(tenant, Json::Null) {
            return None;
        }
        Some(tenant.to_s())
    })
}

/// Port of `rust/project/domain_generator.rb#tenant_boundary_checks`
/// (ANGLE-8's write-side tenant boundary, PR #595; BUG#130) — see that
/// method's own header for the full argument. Fires only when BOTH the
/// command's own aggregate and a referenced target declare a tenant field,
/// each reachable through `state_reference_check_accessor`'s narrow shape;
/// every other shape bails to "no check", never a wrong answer.
fn tenant_boundary_checks(
    aggregate: &Json,
    command: &Json,
    aggregates_by_name: &HashMap<String, &Json>,
    unsupported_names: &[String],
    value_objects_by_name: &HashMap<String, &Json>,
) -> Vec<TenantBoundaryCheck> {
    let Some(own_tenant_field) = tenant_field_for(aggregate) else {
        return Vec::new();
    };
    let cmd_attrs = command.get("attributes").map(Json::each).unwrap_or(&[]);
    let Some(own_tenant_attr) = cmd_attrs.iter().find(|a| crate::attr::name(a) == own_tenant_field) else {
        return Vec::new();
    };
    let Some(own_accessor) = state_reference_check_accessor(own_tenant_attr, value_objects_by_name) else {
        return Vec::new();
    };
    let aggregate_name = node_name(aggregate).to_string();

    cmd_attrs
        .iter()
        .filter_map(|attr| {
            let target_name = crate::naming::reference_target(crate::attr::type_name(attr))?;
            let target = aggregates_by_name.get(target_name)?;
            if unsupported_names.iter().any(|n| n == target_name) {
                return None;
            }
            let target_tenant_field = tenant_field_for(target)?;
            let target_attrs = target.get("attributes").map(Json::each).unwrap_or(&[]);
            let target_tenant_attr = target_attrs.iter().find(|a| crate::attr::name(a) == target_tenant_field)?;
            let target_accessor = state_reference_check_accessor(target_tenant_attr, value_objects_by_name)?;
            Some(TenantBoundaryCheck {
                reference_field: crate::attr::name(attr).to_string(),
                target_mod: node_name(target).to_lowercase(),
                target_name: node_name(target).to_string(),
                aggregate_name: aggregate_name.clone(),
                own_tenant_field: own_tenant_field.clone(),
                own_accessor: own_accessor.clone(),
                target_tenant_field,
                target_accessor,
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
    // THE COVERAGE MANIFEST — `domain_generator.rb`'s own `manifest`
    // array; see `manifest.rs`.
    let mut manifest = Manifest::default();
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

        // Checked against the DOMAIN-MERGED value-object map, exactly as
        // `domain_generator.rb` does (`Projector.unsupported_attribute_
        // types(aggregate, value_objects_by_name)`), and CASCADED into
        // the manifest: every command/entity/entity-command/port-op the
        // skipped aggregate owns gets its own entry tracing back to the
        // same root cause.
        let unsupported = types::unsupported_attribute_types(aggregate, &value_objects_by_name);
        if !unsupported.is_empty() {
            let aggregate_reason = format!(
                "attribute type(s) {} not generated yet (a bare, non-list entity-typed attribute isn't resolved to a Rust type)",
                unsupported.join(", ")
            );
            manifest.skipped("aggregate", format!("{domain_name}::{agg_name}"), aggregate_reason.clone());
            let cascade = format!("owning aggregate not generated: {aggregate_reason}");
            for command in aggregate.get("commands").map(Json::each).unwrap_or(&[]) {
                manifest.skipped("command", format!("{domain_name}::{agg_name}.{}", node_name(command)), cascade.clone());
            }
            for entity in aggregate.get("entities").map(Json::each).unwrap_or(&[]) {
                let entity_verb = format!("{domain_name}::{agg_name}.{}", node_name(entity));
                manifest.skipped("entity", entity_verb.clone(), cascade.clone());
                for command in entity.get("commands").map(Json::each).unwrap_or(&[]) {
                    manifest.skipped("entity_command", format!("{entity_verb}.{}", node_name(command)), cascade.clone());
                }
            }
            for port in aggregate.get("ports").map(Json::each).unwrap_or(&[]) {
                for operation in port.get("operations").map(Json::each).unwrap_or(&[]) {
                    manifest.skipped(
                        "port_operation",
                        format!("{domain_name}::{agg_name}.{}.{}", node_name(port), node_name(operation)),
                        cascade.clone(),
                    );
                }
            }
            continue;
        }
        manifest.generated("aggregate", format!("{domain_name}::{agg_name}"));

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
                        false,
                        false,
                        None,
                    ),
                );
            }
            puts_blank(&mut out);
        }

        let mut entity_commands: Vec<EntityCommandEntry> = Vec::new();
        let mut nested_entity_commands: Vec<NestedEntityCommandEntry> = Vec::new();
        // THIS AGGREGATE'S OWN NESTED ENTITIES, name + identity paths
        // only (BUG#10) — mirrors `domain_generator.rb`'s own identical
        // `entities:` collection, one level up from `entity_commands`
        // above: every entity this aggregate directly declares gets an
        // entry here regardless of whether any of its OWN commands ended
        // up routable (`entity_can_route`, below) — `reactions.rs`'s own
        // `emit_entity_identity_head_table` needs the entity's identity
        // shape, not its own command routability.
        let mut registry_entities: Vec<EntityIdentityEntry> = Vec::new();

        for entity in aggregate.get("entities").map(Json::each).unwrap_or(&[]) {
            let entity_verb = format!("{domain_name}::{agg_name}.{}", node_name(entity));
            manifest.generated("entity", entity_verb.clone());
            registry_entities.push(EntityIdentityEntry {
                name: entity.get("name").and_then(Json::as_str).unwrap_or("").to_string(),
                identified_by: entity.get("identified_by").map(Json::each).unwrap_or(&[]).iter().map(Json::to_s).collect(),
            });
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
            // (`ProcessManager.Handler.Dispatch`). Struct + JSON codec,
            // mirroring rust/project/domain_generator.rb's own identical
            // shape exactly.
            //
            // BUG#11 (loop-parity) — ITS OWN COMMANDS ARE NOW ROUTED
            // TOO, for the ROUTED (`to: { aggregate:, entities: [...] }`)
            // addressing shape. See `commands.rs::emit_nested_entity_
            // command`'s own doc comment and `rust/project/domain_
            // generator.rb`'s own header for the full argument — short
            // version: `kernel::dispatch_entity`/`kernel::apply_entity_
            // command` (dispatch.rs) were already generic enough to
            // compose one hop deeper with no kernel change at all, so
            // this was a real, bounded codegen gap, not an architecture
            // mismatch. Deliberately NOT generalized past two levels —
            // still real, separate, still-open scope.
            //
            // BUG#19 (loop-parity) — BUG#11 deliberately shipped ROUTED
            // ONLY, refusing every FLAT-args depth-2 dispatch (one
            // identity head per hop, no `to:` at all — the same
            // convention `entity_arms`'s own depth-1 `None =>` branch
            // already resolves) with `TypeMismatch`, even though Ruby's
            // `locate_chain` never distinguished the two addressing
            // modes. `entity_can_route`, computed here (moved up from
            // below — the nested loop needs it too now), gates whether
            // `entity`'s own identity supports `extract_id`/`extract_
            // wants` at all; `nested_can_route`, computed per `nested`
            // below, is the same check one hop deeper. Both true is what
            // `unrouted_supported` (each `NestedEntityCommandEntry`, read
            // by `registry.rs`'s own `nested_entity_arms`) actually
            // gates — extending the two-hop router with the identical
            // `Some(route) => ... | None => ...` shape `entity_arms`
            // already has, never a new mechanism.
            let entity_can_route = json_codec::extract_id_supported(entity);

            for nested in entity.get("entities").map(Json::each).unwrap_or(&[]) {
                let nested_verb = format!("{entity_verb}.{}", node_name(nested));
                manifest.generated("entity", nested_verb.clone());
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
                // `identity()` — what a ROUTED dispatch needs off a
                // doubly-nested element (`matches = |el| el.identity()
                // == hop2_id`), emitted unconditionally the way
                // `entity`'s own always is.
                puts_str(&mut out, &json_codec::emit_self_identity(exemplar, nested));
                puts_blank(&mut out);

                // BUG#19 — `extract_id`/`extract_wants`, back FLAT-args
                // addressing at this depth exactly the way `entity_can_
                // route` already backs it one hop shallower (below,
                // `entity`'s own). Needs BOTH hops' identity shape to
                // support it (a flat dispatch has to resolve `hop1_id`
                // off `entity`'s own `extract_id` too — `registry.rs`'s
                // own `nested_entity_arms`, `None =>` branch), so this is
                // gated on `entity_can_route && nested_can_route`, not
                // `nested_can_route` alone.
                let nested_can_route = json_codec::extract_id_supported(nested);
                let unrouted_supported = entity_can_route && nested_can_route;
                if unrouted_supported {
                    puts_str(&mut out, &json_codec::emit_extract_id(exemplar, nested));
                    puts_blank(&mut out);
                    // BUG#140 — see `rust/project/domain_generator.rb`'s
                    // own identical comment.
                    puts_str(&mut out, &json_codec::emit_extract_id_lenient(exemplar, nested));
                    puts_blank(&mut out);
                    puts_str(&mut out, &json_codec::emit_extract_wants(exemplar, nested));
                    puts_blank(&mut out);
                }

                let nested_identified_by = nested.get("identified_by").map(Json::each).unwrap_or(&[]);
                for command in nested.get("commands").map(Json::each).unwrap_or(&[]) {
                    let nested_command_verb = format!("{nested_verb}.{}", node_name(command));
                    if let Some(reason) = commands::entity_command_skip_reason(command, nested, &value_objects_by_name) {
                        manifest.skipped("entity_command", nested_command_verb, reason);
                        continue;
                    }

                    puts_str(
                        &mut out,
                        &commands::emit_nested_entity_command(
                            exemplar,
                            command,
                            nested,
                            entity,
                            aggregate,
                            domain_name,
                            &value_objects_by_name,
                            &aggregates_by_name,
                            &process_managers,
                        ),
                    );
                    puts_blank(&mut out);

                    manifest.record(
                        "entity_command",
                        nested_command_verb,
                        true,
                        Some(true),
                        None,
                        Some(if unrouted_supported {
                            "routed (`to: { entities: [...] }`) and flat-args (one identity head per hop) both supported (BUG#19)".to_string()
                        } else {
                            "routed (`to: { entities: [...] }`) only — no legacy/flat-argument fallback at this depth (identity shape isn't extract_id-supported at one or both hops; BUG#19's own gate)".to_string()
                        }),
                    );

                    let nested_command_name = command.get("name").and_then(Json::as_str).unwrap_or("");
                    let entity_name_str = entity.get("name").and_then(Json::as_str).unwrap_or("");
                    let nested_name_str = nested.get("name").and_then(Json::as_str).unwrap_or("");
                    nested_entity_commands.push(NestedEntityCommandEntry {
                        verb: format!("{domain_name}::{agg_name}.{entity_name_str}.{nested_name_str}.{nested_command_name}"),
                        name: nested_command_name.to_string(),
                        entity_record: entity_name_ident.clone(),
                        nested_record: nested_name_ident.clone(),
                        fn_name: format!(
                            "{}_{}_{}",
                            entity_name_str.to_lowercase(),
                            nested_name_str.to_lowercase(),
                            crate::naming::dispatch_fn_name(&crate::naming::rust_ident(nested_command_name))
                        ),
                        args_struct: format!(
                            "{nested_name_ident}{}NestedEntityArgs",
                            crate::naming::rust_ident(nested_command_name)
                        ),
                        reference_checks: reference_checks(command, &aggregates_by_name, &unsupported_names),
                        reference_specs: crate::reference_specs::reference_specs(
                            domain_name,
                            command.get("attributes").map(Json::each).unwrap_or(&[]),
                        ),
                        attributes: command
                            .get("attributes")
                            .map(Json::each)
                            .unwrap_or(&[])
                            .iter()
                            .map(|a| a.get("name").map(Json::to_s).unwrap_or_default())
                            .collect(),
                        invariant_check_lines: commands::invariant_checks_for(
                            exemplar,
                            command,
                            &aggregates_by_name,
                            &value_objects_by_name,
                        ),
                        role: command.get("role").map(Json::to_s),
                        entity_name: entity_name_str.to_string(),
                        entity_identity_reading: entity
                            .get("identified_by")
                            .map(Json::each)
                            .unwrap_or(&[])
                            .iter()
                            .map(Json::to_s)
                            .collect::<Vec<_>>()
                            .join(", "),
                        nested_name: nested_name_str.to_string(),
                        nested_identity_reading: nested_identified_by
                            .iter()
                            .map(Json::to_s)
                            .collect::<Vec<_>>()
                            .join(", "),
                        unrouted_supported,
                        // BUG#38 — see `EntityCommandEntry`'s own
                        // identical field, above. `None` when `unrouted_
                        // supported` is false: the ROUTED-only shape
                        // never calls `extract_id` against raw
                        // `facts_json`, so there is no race to close.
                        structural_precheck: if unrouted_supported {
                            let identity_heads: Vec<String> = entity
                                .get("identified_by")
                                .map(Json::each)
                                .unwrap_or(&[])
                                .iter()
                                .chain(nested_identified_by.iter())
                                .map(|p| p.to_s().split('.').next().unwrap_or("").to_string())
                                .collect();
                            let allowlist = crate::json_codec::command_argument_allowlist(
                                aggregate, command, &process_managers, &identity_heads,
                            );
                            let cmd_attrs = command.get("attributes").map(Json::each).unwrap_or(&[]);
                            Some(crate::json_codec::structural_precheck(
                                &format!(
                                    "{nested_name_ident}{}NestedEntityArgs",
                                    crate::naming::rust_ident(nested_command_name)
                                ),
                                nested_command_name,
                                cmd_attrs,
                                Some(&allowlist),
                            ))
                        } else {
                            None
                        },
                    });
                }
            }

            // `entity_can_route` — computed once, above, before this
            // aggregate's own nested-entities loop (BUG#19 needs it
            // there too).
            if entity_can_route {
                puts_str(&mut out, &json_codec::emit_extract_id(exemplar, entity));
                puts_blank(&mut out);
                // BUG#140 — see `rust/project/domain_generator.rb`'s own
                // identical comment.
                puts_str(&mut out, &json_codec::emit_extract_id_lenient(exemplar, entity));
                puts_blank(&mut out);
                puts_str(&mut out, &json_codec::emit_extract_wants(exemplar, entity));
                puts_blank(&mut out);
                puts_str(&mut out, &json_codec::emit_self_identity(exemplar, entity));
                puts_blank(&mut out);
            }

            for command in entity.get("commands").map(Json::each).unwrap_or(&[]) {
                let entity_command_verb = format!("{entity_verb}.{}", node_name(command));
                if let Some(reason) = commands::entity_command_skip_reason(command, entity, &value_objects_by_name) {
                    manifest.skipped("entity_command", entity_command_verb, reason);
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
                        &process_managers,
                    ),
                );
                puts_blank(&mut out);

                // THE ROUTABILITY SPLIT — the function above is real, but
                // unreachable through the JSON router when the ENTITY's
                // identity isn't `extract_id`-supported.
                if !entity_can_route {
                    manifest.unrouted(
                        "entity_command",
                        entity_command_verb,
                        format!(
                            "generated as a real Rust function, but not JSON-dispatchable — identity {} isn't a shape extract_id resolves yet (json_codec.rb)",
                            ruby_inspect(entity.get_raw("identified_by"))
                        ),
                    );
                    continue;
                }
                manifest.routed("entity_command", entity_command_verb);

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
                        "{entity_name_ident}{}EntityArgs",
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
                    attributes: command
                        .get("attributes")
                        .map(Json::each)
                        .unwrap_or(&[])
                        .iter()
                        .map(|a| a.get("name").map(Json::to_s).unwrap_or_default())
                        .collect(),
                    invariant_check_lines: commands::invariant_checks_for(
                        exemplar,
                        command,
                        &aggregates_by_name,
                        &value_objects_by_name,
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
                    // BUG#38/#136 (qa/bluebook/quality_control.bluebook)
                    // — the SAME allowlist `commands::emit_entity_
                    // command`'s own `Args::from_json` call already
                    // builds (`extra_identity_heads:` included), run
                    // through `json_codec::structural_precheck` so
                    // `registry.rs`'s router can run the identical
                    // unknown/absent-argument gate a second time,
                    // standalone, against raw `facts_json`, BEFORE the
                    // route-less `None` arm resolves `extract_id` — and
                    // (BUG#136) that same `None` arm now ALSO reruns the
                    // full `Args::from_json` itself, discarded, ahead of
                    // `extract_id`, so a declared identity-echo
                    // attribute's own VO-level coercion runs before
                    // identity resolution too — see `EntityCommandEntry::
                    // structural_precheck`'s own header for the full
                    // reasoning.
                    structural_precheck: {
                        let entity_identity_heads: Vec<String> = identified_by
                            .iter()
                            .map(|p| p.to_s().split('.').next().unwrap_or("").to_string())
                            .collect();
                        let allowlist = crate::json_codec::command_argument_allowlist(
                            aggregate, command, &process_managers, &entity_identity_heads,
                        );
                        let cmd_attrs = command.get("attributes").map(Json::each).unwrap_or(&[]);
                        Some(crate::json_codec::structural_precheck(
                            &format!("{entity_name_ident}{}EntityArgs", crate::naming::rust_ident(entity_command_name)),
                            entity_command_name,
                            cmd_attrs,
                            Some(&allowlist),
                        ))
                    },
                });
            }
        }

        // `record_for_struct`/`record_attrs` — `aggregate[:attributes]`
        // plus a pseudo-attribute per `projects` field (`types.rs`'s own
        // `projected_field_pseudo_attributes` header), matching
        // `domain_generator.rb`'s identical merge: the record's own
        // struct/Fielded/JSON shape carries a seeded projection exactly
        // like any other attribute; a command's own Args struct never
        // sees this (built elsewhere, from `command[:attributes]` alone).
        let record_for_struct = types::with_projected_field_pseudo_attributes(aggregate);
        puts_str(
            &mut out,
            &types::emit_record(exemplar, &record_for_struct, &value_objects_by_name),
        );
        puts_blank(&mut out);
        let record_attrs_owned = record_for_struct.get("attributes").map(Json::each).unwrap_or(&[]).to_vec();
        let record_attrs = record_attrs_owned.as_slice();
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
        puts_str(&mut out, &types::emit_set_projected_field(aggregate));
        puts_blank(&mut out);
        puts_str(&mut out, &types::emit_projected_field_table(aggregate));
        puts_blank(&mut out);

        if can_route {
            puts_str(&mut out, &json_codec::emit_extract_id(exemplar, aggregate));
            puts_blank(&mut out);
        }

        puts_str(&mut out, &commands::emit_invariants_fn(aggregate));
        puts_blank(&mut out);

        let mut registry_commands: Vec<CommandEntry> = Vec::new();
        for command in aggregate.get("commands").map(Json::each).unwrap_or(&[]) {
            let command_verb = format!("{domain_name}::{agg_name}.{}", node_name(command));
            if let Some(reason) = commands::command_skip_reason(command, aggregate, &value_objects_by_name) {
                manifest.skipped("command", command_verb, reason);
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
                &json_codec::emit_to_json_flat_sparse(exemplar, &args_struct, cmd_attrs, &value_objects_by_name),
            );
            puts_blank(&mut out);
            let allowlist =
                json_codec::command_argument_allowlist(aggregate, command, &process_managers, &[]);
            puts_str(
                &mut out,
                &json_codec::emit_from_json_flat(
                    exemplar,
                    &args_struct,
                    cmd_attrs,
                    &value_objects_by_name,
                    Some(&allowlist),
                    Some(command_name),
                    true,
                    true,
                    Some(&aggregates_by_name),
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
                manifest.unrouted(
                    "command",
                    command_verb,
                    format!(
                        "generated as a real Rust function, but not JSON-dispatchable — identity {} isn't a shape extract_id resolves yet (json_codec.rb)",
                        ruby_inspect(aggregate.get_raw("identified_by"))
                    ),
                );
                continue;
            }
            manifest.routed("command", command_verb);

            // BUG#23 (qa/bluebook/quality_control.bluebook) — the SAME
            // `allowlist` this command's own `emit_from_json_flat` call
            // above already built, run through `json_codec::structural_
            // precheck` so `registry.rs`'s router can run the identical
            // unknown/absent-argument gate a second time, standalone,
            // against raw `facts_json`, BEFORE `id_line` resolves — see
            // that function's own header for the full reasoning.
            // Computed here, into a plain local, rather than inline
            // inside the `CommandEntry` literal below: `args_struct` is
            // moved into that literal's own `args_struct` field, and
            // struct-literal field initializers evaluate in the order
            // written, so borrowing it again in a LATER field expression
            // would use it after that move. `None` for a CREATING
            // command: `id_line` (registry.rs's own `if c.creates {
            // ... } else { ... }`) resolves no IDENTITY at all there —
            // a creating command's own identity comes from its declared
            // attributes, never from `facts_json` — so there is no
            // identity-resolution-before-structural-checks race for this
            // fix to close there. BUG#56 (qa/bluebook/quality_control.
            // bluebook) later gave a creating command's own `id_line` a
            // real body too — an eager `route.require_depth(0)?`
            // precheck — but that validates `route`, a piece of data
            // entirely separate from `facts_json`, so it still cannot
            // race this field's own check.
            let structural_precheck = if creates {
                None
            } else {
                Some(json_codec::structural_precheck(
                    &args_struct,
                    command_name,
                    cmd_attrs,
                    Some(&allowlist),
                ))
            };

            registry_commands.push(CommandEntry {
                verb: format!("{domain_name}::{agg_name}.{command_name}"),
                name: command_name.to_string(),
                fn_name: crate::naming::dispatch_fn_name(&crate::naming::rust_ident(command_name)),
                args_struct,
                creates,
                identity_extra_params,
                // `state_reference_checks` — ADR 0037 Finding 5 (reopened,
                // QualityControl BUG#26): only ever adds entries
                // `reference_checks` above didn't already cover — see
                // that function's own header.
                reference_checks: {
                    let mut checks = reference_checks(command, &aggregates_by_name, &unsupported_names);
                    checks.extend(state_reference_checks(aggregate, command, &aggregates_by_name, &unsupported_names, &value_objects_by_name));
                    checks
                },
                // ANGLE-8 / BUG#130 — `tenant_boundary_checks`'s own header.
                tenant_boundary_checks: tenant_boundary_checks(
                    aggregate,
                    command,
                    &aggregates_by_name,
                    &unsupported_names,
                    &value_objects_by_name,
                ),
                reference_specs: crate::reference_specs::reference_specs(domain_name, cmd_attrs),
                attributes: cmd_attrs
                    .iter()
                    .map(|a| a.get("name").map(Json::to_s).unwrap_or_default())
                    .collect(),
                invariant_check_lines: commands::invariant_checks_for(
                    exemplar,
                    command,
                    &aggregates_by_name,
                    &value_objects_by_name,
                ),
                role: command.get("role").map(Json::to_s),
                structural_precheck,
            });
        }

        let mut port_operations: Vec<PortEntry> = Vec::new();
        for port in aggregate.get("ports").map(Json::each).unwrap_or(&[]) {
            let port_name = port.get("name").and_then(Json::as_str).unwrap_or("");
            for operation in port.get("operations").map(Json::each).unwrap_or(&[]) {
                let operation_verb = format!("{domain_name}::{agg_name}.{port_name}.{}", node_name(operation));
                if let Some(reason) = ports::port_operation_skip_reason(operation, agg_name, &value_objects_by_name) {
                    manifest.skipped("port_operation", operation_verb, reason);
                    continue;
                }
                manifest.routed("port_operation", operation_verb);

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
            nested_entity_commands,
            ports: port_operations,
            chapter_mod: mod_name.to_string(),
            domain_name: domain_name.to_string(),
            reference_specs: crate::reference_specs::reference_specs(
                domain_name,
                aggregate.get("attributes").map(Json::each).unwrap_or(&[]),
            ),
            identified_by: aggregate.get("identified_by").map(Json::each).unwrap_or(&[]).iter().map(Json::to_s).collect(),
            entities: registry_entities,
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
            let query_name = query.get("name").and_then(Json::as_str).unwrap_or("");
            if let Some(reason) = queries::query_skip_reason(query, aggregate, &value_objects_by_name) {
                manifest.skipped("query", format!("{domain_name}::{agg_name}.{query_name}"), reason);
                continue;
            }
            manifest.generated("query", format!("{domain_name}::{agg_name}.{query_name}"));

            query_defs.push(queries::QueryDef {
                verb: format!("{domain_name}::{agg_name}.{query_name}"),
                aggregate: format!("{domain_name}::{agg_name}"),
                arg_checks: queries::query_arg_checks(query, &format!("crate::generated::{mod_name}::{}", agg_name.to_lowercase()), &value_objects_by_name),
                conditions: queries::query_conditions_with_authorization(query),
                order_by: query.get("order_by").map(|ob| queries::emit_query_order_by(ob, query.get("null_semantics"))),
                offset: query.get("offset").map(queries::emit_query_offset),
                limit: query.get("limit").map(queries::emit_query_limit),
                authorization: queries::emit_query_authorization(query_name, query.get("authorization")),
            });
        }
    }

    // ── READ MODELS.
    let mut read_model_defs: Vec<read_models::ReadModelDef> = Vec::new();
    for read_model in ir.get("read_models").map(Json::each).unwrap_or(&[]) {
        let read_model_id = format!("{domain_name}::{}", node_name(read_model));
        if let Some(reason) = read_models::read_model_skip_reason(read_model, &aggregates_by_name, &unsupported_names) {
            manifest.skipped("read_model", read_model_id, reason);
            continue;
        }
        manifest.generated("read_model", read_model_id);
        read_model_defs.push(read_models::read_model_def(
            domain_name,
            read_model,
            &aggregates_by_name,
        ));
    }

    // ── POLICIES / PROCESS MANAGERS — no per-instance skip condition on
    // either (see `domain_generator.rb`'s own comments on both loops).
    for policy in ir.get("policies").map(Json::each).unwrap_or(&[]) {
        manifest.routed("policy", format!("{domain_name}::{}", node_name(policy)));
    }
    for pm in &process_managers {
        manifest.routed("process_manager", format!("{domain_name}::{}", node_name(pm)));
    }
    // ── LINEAGE-CAPABLE AGGREGATES — `ir[:lineage][:capable_aggregates]`,
    // generated/routed unconditionally (rust/host's journal path is
    // generic over `storage_name`).
    let lineage_aggregates = ir.get("lineage").and_then(|l| l.get("capable_aggregates")).map(Json::each).unwrap_or(&[]);
    for lineage_aggregate in lineage_aggregates {
        manifest.record(
            "lineage_aggregate",
            format!("{domain_name}::{}", node_name(lineage_aggregate)),
            true,
            Some(true),
            None,
            Some(format!(
                "read via rust/host's journal::read_lineage_head_all/_by_id, written via journal::append_lineage_mutation — both generic over storage_name (\"{}\"), dispatched OUTSIDE the WASM kernel/InMemoryRepository path entirely, matching Ruby's own CommandInterpreter routing for a Postgres-bound aggregate (rust/project.rb's own header)",
                lineage_aggregate.get("storage_name").map(Json::to_s).unwrap_or_default()
            )),
        );
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
        &reactions::emit_entity_identity_head_table(exemplar, &registry_aggregates),
    );
    puts_blank(&mut registry_rs);
    puts_str(
        &mut registry_rs,
        &reactions::emit_command_attributes_table(exemplar, &registry_aggregates),
    );
    puts_blank(&mut registry_rs);
    puts_str(
        &mut registry_rs,
        &queries::emit_query_table(exemplar, &query_defs),
    );
    puts_blank(&mut registry_rs);
    puts_str(&mut registry_rs, &queries::emit_query_arg_check_table(&query_defs));
    puts_blank(&mut registry_rs);
    for rmd in &read_model_defs {
        if let Some(body) = &rmd.group_by_fn_body {
            puts_str(&mut registry_rs, body);
            puts_blank(&mut registry_rs);
        }
    }
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
        manifest_json: manifest.to_json_text(),
    }
}
