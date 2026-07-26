//! Canonical IR dump — JSON shape that both Ruby and Rust must agree on.
//!
//! Hand-written framework source. Was generated from codegen/dump_shape until
//! 2026-06-27, when the self-projection codegen was retired — a .bluebook whose
//! only job is to re-emit imperative Rust captures no domain.
//!
//! This is the parity contract. Hand-written so the JSON shape is chosen
//! explicitly, not accidentally derived from Rust struct field names or
//! serde defaults. When the Ruby BluebookModel serializer (canonical_ir.rb)
//! produces the same shape, both parsers can be diffed deterministically.
//!
//! Shape:
//!   { name, category, vision, aggregates[], policies[], fixtures[], vows[] }
//!
//! Each Aggregate, Command, Attribute, etc. has a fixed key order and
//! omits no fields (uses null where absent). Stable field naming —
//! `attributes[*].type` (not Rust's internal `attr_type`),
//! `references[*].target`, etc. — so the contract reads naturally.
//!
//! Usage:
//!   storehouse dump path/to/foo.bluebook
//!   # → JSON to stdout, exit 0

use crate::ir::{
    Aggregate, Attribute, Cardinality, Command, Direction, Domain, Entity, Factory, Fixture, Given,
    Invariant, Lifecycle, LimitSpec, Mutation, MutationOp, OrderBy, Policy,
    DispatchSpec, ProcessManager, ProcessManagerHandler, Query, Reference, ReferenceKind, Transition, ValueSpec,
    ValueObject, View, WhereClause, WhereOp,
};
use serde_json::{json, Value};

pub fn dump(domain: &Domain) -> Value {
    json!({
        "name": domain.name,
        "version": domain.version,
        "category": domain.category,
        "vision": domain.vision,
        "aggregates": domain.aggregates.iter().map(dump_aggregate).collect::<Vec<_>>(),
        "policies": domain.policies.iter().map(dump_policy).collect::<Vec<_>>(),
        "fixtures": domain.fixtures.iter().map(dump_fixture).collect::<Vec<_>>(),
        "process_managers": domain.process_managers.iter().map(dump_process_manager).collect::<Vec<_>>(),
    })
}

fn dump_process_manager(pm: &ProcessManager) -> Value {
    json!({
        "name": pm.name,
        "correlates_by": pm.correlates_by,
        "starts_on": pm.starts_on,
        "ends_on": pm.ends_on,
        "states": pm.states,
        "handlers": pm.handlers.iter().map(dump_pm_handler).collect::<Vec<_>>(),
    })
}

fn dump_pm_handler(h: &ProcessManagerHandler) -> Value {
    let set_pairs: Vec<Value> = h
        .set_specs
        .iter()
        .map(|(k, spec)| json!([k, dump_value_spec(spec)]))
        .collect();
    json!({
        "dispatches": h.dispatches.iter().map(dump_dispatch).collect::<Vec<_>>(),
        "event_type": h.event_type,
        "from_state": h.from_state,
        "set_specs": set_pairs,
        "to_state": h.to_state,
    })
}

/// Mirror Ruby's CanonicalIR.dump_dispatch. Phase 2.b
/// (pm-dispatch-enrichment) — dispatches carry a structured
/// command_name + ordered with-spec map. i221-A — also emit a
/// `for_each` key (Some sweep → object, None → null).
fn dump_dispatch(d: &DispatchSpec) -> Value {
    let with_pairs: Vec<Value> = d
        .with_spec
        .iter()
        .map(|(k, spec)| json!([k, dump_value_spec(spec)]))
        .collect();
    let for_each = match &d.for_each {
        Some(fe) => json!({
            "source_context": fe.source_context,
            "source_aggregate": fe.source_aggregate,
            "query_name": fe.query_name,
            "query_inputs": fe.query_inputs.iter()
                .map(|(k, spec)| json!([k, dump_value_spec(spec)]))
                .collect::<Vec<_>>(),
        }),
        None => Value::Null,
    };
    json!({
        "command_name": d.command_name,
        "for_each": for_each,
        "with": with_pairs,
    })
}

/// Mirror Ruby's CanonicalIR.dump_value_spec. Four kinds : literal,
/// from_event, from_pm, from_iter (i221-A). Defaults serialise as
/// JSON null when absent.
fn dump_value_spec(spec: &ValueSpec) -> Value {
    match spec {
        ValueSpec::Literal { value } => json!({
            "kind": "literal",
            "value": value,
        }),
        ValueSpec::FromEvent { name, default } => json!({
            "kind": "from_event",
            "name": name,
            "default": default,
        }),
        ValueSpec::FromPm { name, default } => json!({
            "kind": "from_pm",
            "name": name,
            "default": default,
        }),
        ValueSpec::FromIter { field } => json!({
            "kind": "from_iter",
            "field": field,
        }),
    }
}

fn dump_aggregate(agg: &Aggregate) -> Value {
    json!({
        "name": agg.name,
        "context": agg.context,
        "description": agg.description,
        // 2026-07-18 — aggregate identified_by joins the canonical IR
        // (it was un-guarded by parity until the payload-gate arc).
        // Same slot as dump_entity's : after description, before attributes.
        "identified_by": agg.identified_by,
        "attributes": agg.attributes.iter().map(dump_attribute).collect::<Vec<_>>(),
        "value_objects": agg.value_objects.iter().map(dump_value_object).collect::<Vec<_>>(),
        "entities": agg.entities.iter().map(dump_entity).collect::<Vec<_>>(),
        "references": agg.references.iter().map(dump_reference).collect::<Vec<_>>(),
        "factories": agg.factories.iter().map(dump_factory).collect::<Vec<_>>(),
        "commands": agg.commands.iter().map(dump_command).collect::<Vec<_>>(),
        "queries": agg.queries.iter().map(dump_query).collect::<Vec<_>>(),
        "lifecycle": agg.lifecycle.as_ref().map(dump_lifecycle),
        "invariants": agg.invariants.iter().map(dump_invariant).collect::<Vec<_>>(),
        "views": agg.views.iter().map(dump_view).collect::<Vec<_>>(),
    })
}

fn dump_attribute(attr: &Attribute) -> Value {
    json!({
        "name": attr.name,
        "type": attr.attr_type,
        "list": attr.list,
        "default": attr.default,
        // 2026-07-18 — the payload gate enforces `required: true`, so the
        // flag joins the canonical IR (both parsers already carried it).
        "required": attr.required,
        // one_of scalar vocabulary (2026-07-19). Key named `one_of` — the
        // canonical IR reads as words, not code ("enum is too codey" —
        // Chris, same session ; the `enum:` kwarg spelling was migrated
        // out of all 20 corpus files and is retired : any future usage
        // drifts loudly because only the Ruby side would collect it).
        "one_of": attr.enum_values,
        // pattern scalar SHAPE (GRAMMAR-pattern) — the closed-shape sibling of
        // one_of's closed vocabulary. Both parsers carry it, so a pattern that
        // only one side collected drifts loudly here rather than silently
        // enforcing on one target and not the other.
        "pattern": attr.pattern,
        // hint (GRAMMAR-pattern) — human guidance for a shape mismatch. Both
        // parsers carry it so it round-trips through the canonical IR.
        "hint": attr.hint,
    })
}

fn dump_value_object(vo: &ValueObject) -> Value {
    json!({
        "name": vo.name,
        "description": vo.description,
        "attributes": vo.attributes.iter().map(dump_attribute).collect::<Vec<_>>(),
        // 2026-07-18 — VO invariants, NAMES ONLY : the Ruby side holds the
        // predicate as a Proc (source unrecoverable), so the shared canonical
        // contract is the invariant's name ; each runtime enforces the
        // predicate from its own parse. The Rust IR keeps the expression
        // internally (payload_gate) — it just isn't part of the parity
        // contract.
        "invariants": vo.invariants.iter().map(|i| json!({"name": i.name})).collect::<Vec<_>>(),
        // 2026-07-21 — VO derivations, SIGNATURE ONLY (name + return_type +
        // param names) : the body is a Ruby Proc on the Ruby side, so the
        // shared contract excludes the expression, exactly like invariants.
        // Each runtime evaluates its own parse of the body.
        "derivations": vo.derivations.iter().map(|d| json!({
            "name": d.name,
            "return_type": d.return_type,
            "params": d.params,
        })).collect::<Vec<_>>(),
        // one_of members (2026-07-19) — ordered objects, declaration order
        // on both sides (Ruby kwargs preserve insertion order).
        "members": vo.members.iter().map(|m| {
            let mut obj = serde_json::Map::new();
            for (k, v) in m {
                obj.insert(k.clone(), serde_json::Value::String(v.clone()));
            }
            serde_json::Value::Object(obj)
        }).collect::<Vec<_>>(),
    })
}

fn dump_reference(r: &Reference) -> Value {
    json!({
        "name": r.name,
        "target": r.target,
        "domain": r.domain,
        "kind": dump_reference_kind(&r.kind),
        "cardinality": dump_cardinality(&r.cardinality),
    })
}

fn dump_command(cmd: &Command) -> Value {
    json!({
        "name": cmd.name,
        "description": cmd.description,
        "role": cmd.role,
        "emits": cmd.emits,
        "emits_identified_by": cmd.emits_identified_by,
        "redirects_native": cmd.redirects_native,
        "attributes": cmd.attributes.iter().map(dump_attribute).collect::<Vec<_>>(),
        "references": cmd.references.iter().map(dump_reference).collect::<Vec<_>>(),
        "givens": cmd.givens.iter().map(dump_given).collect::<Vec<_>>(),
        "mutations": cmd.mutations.iter().map(dump_mutation).collect::<Vec<_>>(),
    })
}

fn dump_query(q: &Query) -> Value {
    json!({
        "name": q.name,
        "description": q.description,
        "attributes": q.attributes.iter().map(dump_attribute).collect::<Vec<_>>(),
        "wheres": q.wheres.iter().map(dump_where_clause).collect::<Vec<_>>(),
        "order_by": q.order_by.as_ref().map(dump_order_by),
        "limit": q.limit.as_ref().map(dump_limit_spec),
    })
}

fn dump_given(g: &Given) -> Value {
    json!({
        "expression": g.expression,
        "message": g.message,
    })
}

fn dump_mutation(m: &Mutation) -> Value {
    json!({
        "field": m.field,
        "op": dump_mutation_op(&m.operation),
        "value": normalize_value(&m.value),
    })
}

// Strip whitespace adjacent to brackets/braces/parens. Source representations
// differ ("[ a, b ]" vs "[a, b]") even when semantically identical; both
// runtimes normalize so the canonical output agrees.
fn normalize_value(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut in_str = false;
    let mut prev = '\0';
    let chars: Vec<char> = s.chars().collect();
    for (i, &c) in chars.iter().enumerate() {
        match c {
            '"' if prev != '\\' => { in_str = !in_str; out.push(c); }
            ' ' | '\t' if !in_str => {
                let next = chars.get(i + 1).copied().unwrap_or('\0');
                let just_after_open = matches!(prev, '[' | '{' | '(');
                let just_before_close = matches!(next, ']' | '}' | ')');
                if !just_after_open && !just_before_close { out.push(c); }
            }
            _ => out.push(c),
        }
        prev = c;
    }
    out
}

fn dump_mutation_op(op: &MutationOp) -> &'static str {
    match op {
        MutationOp::Set          => "set",
        MutationOp::Append       => "append",
        MutationOp::Increment    => "increment",
        MutationOp::Decrement    => "decrement",
        MutationOp::Toggle       => "toggle",
        MutationOp::Multiply     => "multiply",
        MutationOp::Clamp        => "clamp",
        MutationOp::Decay        => "decay",
        MutationOp::Delete       => "delete",
        MutationOp::Remove       => "remove",
        MutationOp::AppendUnique => "append_unique",
    }
}

fn dump_reference_kind(k: &ReferenceKind) -> Value {
    json!(k.as_str())
}

fn dump_lifecycle(lc: &Lifecycle) -> Value {
    json!({
        "field": lc.field,
        "default": lc.default,
        "transitions": lc.transitions.iter().map(dump_transition).collect::<Vec<_>>(),
    })
}

fn dump_cardinality(c: &Cardinality) -> Value {
    json!({
        "min": c.min,
        "max": c.max,
    })
}

fn dump_transition(t: &Transition) -> Value {
    json!({
        "command": t.command,
        "to_state": t.to_state,
        "from_state": t.from_state,
    })
}

fn dump_policy(p: &Policy) -> Value {
    json!({
        "name": p.name,
        "on_event": p.on_event,
        "trigger_command": p.trigger_command,
        "target_domain": p.target_domain,
    })
}

fn dump_fixture(f: &Fixture) -> Value {
    // Use array of [key, value] pairs to preserve order — same shape Ruby will emit.
    let pairs: Vec<Value> = f.attributes.iter()
        .map(|(k, v)| json!([k, normalize_value(v)]))
        .collect();
    json!({
        "name": f.name,
        "aggregate_name": f.aggregate_name,
        "attributes": pairs,
    })
}

fn dump_entity(ent: &Entity) -> Value {
    json!({
        "name": ent.name,
        "description": ent.description,
        "identified_by": ent.identified_by,
        "attributes": ent.attributes.iter().map(dump_attribute).collect::<Vec<_>>(),
        "commands": ent.commands.iter().map(dump_command).collect::<Vec<_>>(),
        "queries": ent.queries.iter().map(dump_query).collect::<Vec<_>>(),
        "lifecycle": ent.lifecycle.as_ref().map(dump_lifecycle),
    })
}

fn dump_where_clause(w: &WhereClause) -> Value {
    json!({
        "field": w.field,
        "op": dump_where_op(&w.op),
        "value": w.value,
    })
}

fn dump_where_op(op: &WhereOp) -> &'static str {
    match op {
        WhereOp::Eq          => "eq",
        WhereOp::Ne          => "ne",
        WhereOp::Gt          => "gt",
        WhereOp::Gte         => "gte",
        WhereOp::Lt          => "lt",
        WhereOp::Lte         => "lte",
        WhereOp::In          => "in",
        WhereOp::NoneInState => "none_in_state",
        WhereOp::Contains    => "contains",
    }
}

fn dump_order_by(o: &OrderBy) -> Value {
    json!({
        "field": o.field,
        "direction": dump_direction(&o.direction),
    })
}

fn dump_direction(d: &Direction) -> &'static str {
    match d {
        Direction::Asc  => "asc",
        Direction::Desc => "desc",
    }
}

fn dump_limit_spec(l: &LimitSpec) -> Value {
    json!({
        "value": l.value,
    })
}

fn dump_view(v: &View) -> Value {
    json!({
        "name": v.name,
        "show_all": v.show_all,
        "fields": v.fields,
    })
}

fn dump_invariant(inv: &Invariant) -> Value {
    json!({
        "name": inv.name,
        "expression": inv.expression,
    })
}

fn dump_factory(fac: &Factory) -> Value {
    json!({
        "name": fac.name,
        "description": fac.description,
        "role": fac.role,
        "produces": fac.produces,
        "emits": fac.emits,
        "emits_identified_by": fac.emits_identified_by,
        "attributes": fac.attributes.iter().map(dump_attribute).collect::<Vec<_>>(),
        "references": fac.references.iter().map(dump_reference).collect::<Vec<_>>(),
        "givens": fac.givens.iter().map(dump_given).collect::<Vec<_>>(),
        "mutations": fac.mutations.iter().map(dump_mutation).collect::<Vec<_>>(),
    })
}

