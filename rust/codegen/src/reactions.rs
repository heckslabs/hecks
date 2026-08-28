//! Port of `rust/project/reactions.rb` — read that file's own header
//! comments in full; this mirrors its algorithm directly, function for
//! function.

use crate::exemplar::Exemplar;
use crate::json::Json;
use crate::literal::{self, Literal};
use crate::naming;
use crate::registry::AggregateEntry;

pub fn policy_event_qualifier(on_event: &str) -> Option<String> {
    if on_event.contains('.') {
        Some(on_event.splitn(2, '.').next().unwrap_or("").to_string())
    } else {
        None
    }
}

pub fn policy_event_name(on_event: &str) -> String {
    if on_event.contains('.') {
        on_event.splitn(2, '.').nth(1).unwrap_or("").to_string()
    } else {
        on_event.to_string()
    }
}

/// ── THE POLICY TABLE.
pub fn emit_policy_table(exemplar: &Exemplar, domain_name: &str, policies: &[Json], aggregates: &[Json]) -> String {
    let fns = where_fns(policies);
    let rows = local_policy_rows(domain_name, policies, aggregates);
    let table = exemplar.render(
        "policy_table",
        &[("crate::kernel::PolicyRule { policy_name: \"tmpl_policy_name\", event_name: \"tmpl_event_name\", event_qualifier: None, target_verb: \"tmpl_target_verb\", for_each: None, for_each_key: None, with_spec: &[], where_expr: None },", rows.join("\n"))],
    );
    if fns.is_empty() {
        table
    } else {
        format!("{table}\n\n{}", fns.join("\n\n"))
    }
}

/// Port of reactions.rb's `where_fn_name`/`where_expr`/`where_fns` — a
/// policy's `where { … }` as a generated function the kernel calls.
fn where_fn_name(policy: &Json) -> String {
    format!("where_{}", naming::dispatch_fn_name(&naming::rust_ident(&policy.get("name").map(Json::to_s).unwrap_or_default())))
}

fn where_expr(policy: &Json) -> String {
    match policy.get("where").map(Json::to_s) {
        Some(w) if !w.is_empty() => format!("Some({})", where_fn_name(policy)),
        _ => "None".to_string(),
    }
}

fn where_fns(policies: &[Json]) -> Vec<String> {
    policies
        .iter()
        .filter(|policy| policy.get("where").map(Json::to_s).map(|w| !w.is_empty()).unwrap_or(false))
        .map(|policy| {
            let canonical = policy.get("where").map(Json::to_s).unwrap_or_default();
            format!("fn {}() -> crate::kernel::Expr {{\n    use crate::kernel::Expr;\n    {}\n}}", where_fn_name(policy), crate::expr_emitter::emit_predicate(&canonical))
        })
        .collect()
}

fn local_policy_rows(domain_name: &str, policies: &[Json], aggregates: &[Json]) -> Vec<String> {
    policies
        .iter()
        .filter_map(|policy| {
            let target_domain = policy.get("target_domain").map(Json::to_s).unwrap_or_else(|| domain_name.to_string());
            if target_domain != domain_name {
                return None;
            }

            let on_event = policy.get("on_event").map(Json::to_s).unwrap_or_default();
            let event_name = policy_event_name(&on_event);
            let qualifier = policy_event_qualifier(&on_event);
            let qualifier_expr = match qualifier {
                Some(q) => format!("Some({})", naming::ruby_inspect_string(&q)),
                None => "None".to_string(),
            };
            let target_verb = format!("{target_domain}::{}", policy.get("trigger_command").map(Json::to_s).unwrap_or_default());
            let name = policy.get("name").map(Json::to_s).unwrap_or_default();

            Some(format!(
                "    crate::kernel::PolicyRule {{ policy_name: {}, event_name: {}, event_qualifier: {qualifier_expr}, target_verb: {}, for_each: {}, for_each_key: {}, with_spec: {}, where_expr: {} }},",
                naming::ruby_inspect_string(&name),
                naming::ruby_inspect_string(&event_name),
                naming::ruby_inspect_string(&target_verb),
                fan_out_verb_expr(domain_name, policy),
                fan_out_key_expr(policy, aggregates),
                with_spec_expr(policy),
                where_expr(policy)
            ))
        })
        .collect()
}

/// ── THE CROSS-DOMAIN POLICY TABLE.
pub fn emit_cross_domain_policy_table(exemplar: &Exemplar, domain_name: &str, policies: &[Json]) -> String {
    let rows: Vec<String> = policies
        .iter()
        .filter_map(|policy| {
            let target_domain = policy.get("target_domain").map(Json::to_s).unwrap_or_else(|| domain_name.to_string());
            if target_domain == domain_name {
                return None;
            }

            let on_event = policy.get("on_event").map(Json::to_s).unwrap_or_default();
            let event_name = policy_event_name(&on_event);
            let qualifier = policy_event_qualifier(&on_event);
            let qualifier_expr = match qualifier {
                Some(q) => format!("Some({})", naming::ruby_inspect_string(&q)),
                None => "None".to_string(),
            };
            let target_verb = format!("{target_domain}::{}", policy.get("trigger_command").map(Json::to_s).unwrap_or_default());
            let name = policy.get("name").map(Json::to_s).unwrap_or_default();

            Some(format!(
                "    crate::kernel::CrossDomainPolicyRule {{ policy_name: {}, event_name: {}, event_qualifier: {qualifier_expr}, target_domain: {}, target_verb: {}, where_expr: {} }},",
                naming::ruby_inspect_string(&name),
                naming::ruby_inspect_string(&event_name),
                naming::ruby_inspect_string(&target_domain),
                naming::ruby_inspect_string(&target_verb),
                where_expr(policy)
            ))
        })
        .collect();

    if !rows.is_empty() {
        println!("cross-domain policy table: {} row(s) — delivered by rust/host's lambda_client.rs, not locally dispatched", rows.len());
    }

    exemplar.render(
        "cross_domain_policy_table",
        &[(
            "crate::kernel::CrossDomainPolicyRule { policy_name: \"tmpl_policy_name\", event_name: \"tmpl_event_name\", event_qualifier: None, target_domain: \"tmpl_target_domain\", target_verb: \"tmpl_target_verb\", where_expr: None },",
            rows.join("\n"),
        )],
    )
}

fn with_value_parsed(raw: &str) -> Literal {
    literal::read(raw)
}

/// A parsed `with:` literal to a Rust expression BUILDING the equivalent
/// `Json` value.
fn json_literal_expr(value: &Literal) -> String {
    match value {
        Literal::Hash(pairs) => {
            let fields: Vec<String> = pairs.iter().map(|(k, v)| format!("({}.to_string(), {})", naming::ruby_inspect_string(k), json_literal_expr(v))).collect();
            format!("crate::kernel::Json::Object(vec![{}])", fields.join(", "))
        }
        Literal::Str(s) => format!("crate::kernel::Json::Str({}.to_string())", naming::ruby_inspect_string(s)),
        Literal::Int(n) => format!("crate::kernel::Json::int({n})"),
        Literal::Float(n) => format!("crate::kernel::Json::Num({}f64)", ruby_float_text(*n)),
        Literal::Bool(b) => format!("crate::kernel::Json::Bool({b})"),
        Literal::Nil => "crate::kernel::Json::Null".to_string(),
        other => panic!("unsupported with: literal {other:?} — json_literal_expr doesn't cover this shape"),
    }
}

fn ruby_float_text(n: f64) -> String {
    let text = format!("{n}");
    if text.contains('.') || text.contains('e') || text.contains('E') {
        text
    } else {
        format!("{text}.0")
    }
}

// `compensates` — per-dispatch saga compensation (`ir::DispatchSpec::
// compensates`/`Hecks::Bluebook::DispatchSpec#compensates`,
// `lib/hecks/bluebook/process_manager.rb`): absent/`null` on the IR
// (`Json::get` already reads both as `None`) emits `None`; a nested
// object recurses through THIS SAME function one level in. Mirrors
// rust/project/reactions.rb's own `emit_dispatch_spec` exactly — never
// nested further than one level on the Ruby side (a compensation is not
// itself compensable), so this recursion bottoms out in at most one
// extra call.
fn emit_dispatch_spec(exemplar: &Exemplar, spec: &Json, literal_fns: &mut Vec<String>) -> String {
    let with_spec = spec.get("with_spec").map(Json::each).unwrap_or(&[]);
    let with_pairs: Vec<String> = with_spec
        .iter()
        .map(|pair| {
            let kv = pair.as_array().unwrap_or(&[]);
            let key = kv.first().map(Json::to_s).unwrap_or_default();
            let raw = kv.get(1).map(Json::to_s).unwrap_or_default();
            format!("({}, {})", naming::ruby_inspect_string(&key), emit_with_value(exemplar, &raw, literal_fns))
        })
        .collect();
    let compensates = match spec.get("compensates") {
        Some(nested) => format!("Some(&{})", emit_dispatch_spec(exemplar, nested, literal_fns)),
        None => "None".to_string(),
    };
    format!(
        "crate::kernel::DispatchSpec {{ command_name: {}, with: &[{}], compensates: {} }}",
        naming::ruby_inspect_string(&spec.get("command_name").map(Json::to_s).unwrap_or_default()),
        with_pairs.join(", "),
        compensates
    )
}

/// One `with:` binding, resolved to a `WithValue` — a bare Symbol is a
/// RUNTIME reference; anything else is a LITERAL, emitted as its own tiny
/// `fn() -> Json` (`literal_fns` collects these).
fn emit_with_value(exemplar: &Exemplar, raw: &str, literal_fns: &mut Vec<String>) -> String {
    let parsed = with_value_parsed(raw);
    if let Literal::Symbol(name) = &parsed {
        return format!("crate::kernel::WithValue::Ref({})", naming::ruby_inspect_string(name));
    }

    let fn_name = format!("pm_literal_{}", literal_fns.len());
    literal_fns.push(exemplar.render("with_value_literal_fn", &[("tmpl_literal_fn", fn_name.clone()), ("tmpl_body_placeholder()", json_literal_expr(&parsed))]));
    format!("crate::kernel::WithValue::Literal({fn_name})")
}

fn emit_handler(exemplar: &Exemplar, handler: &Json, literal_fns: &mut Vec<String>) -> String {
    let dispatches = handler.get("dispatches").map(Json::each).unwrap_or(&[]);
    let dispatch_strs: Vec<String> = dispatches.iter().map(|d| emit_dispatch_spec(exemplar, d, literal_fns)).collect();
    format!(
        "crate::kernel::Handler {{ event_type: {}, from_state: {}, to_state: {}, dispatches: &[{}] }}",
        naming::ruby_inspect_string(&handler.get("event_type").map(Json::to_s).unwrap_or_default()),
        naming::ruby_inspect_string(&handler.get("from_state").map(Json::to_s).unwrap_or_default()),
        naming::ruby_inspect_string(&handler.get("to_state").map(Json::to_s).unwrap_or_default()),
        dispatch_strs.join(", ")
    )
}

/// ── THE PROCESS MANAGER TABLE.
pub fn emit_process_manager_table(exemplar: &Exemplar, process_managers: &[Json]) -> String {
    let mut literal_fns: Vec<String> = Vec::new();
    let pm_exprs: Vec<String> = process_managers
        .iter()
        .map(|pm| {
            let handlers = pm.get("handlers").map(Json::each).unwrap_or(&[]);
            let handler_strs: Vec<String> = handlers.iter().map(|h| emit_handler(exemplar, h, &mut literal_fns)).collect();
            let states = pm.get("states").map(Json::each).unwrap_or(&[]);
            let initial_state = states.first().map(Json::to_s).unwrap_or_default();
            format!(
                "crate::kernel::ProcessManagerDef {{ name: {}, correlates_by: {}, starts_on: {}, ends_on: {}, initial_state: {}, handlers: &[{}] }}",
                naming::ruby_inspect_string(&pm.get("name").map(Json::to_s).unwrap_or_default()),
                naming::ruby_inspect_string(&pm.get("correlates_by").map(Json::to_s).unwrap_or_default()),
                naming::ruby_inspect_string(&pm.get("starts_on").map(Json::to_s).unwrap_or_default()),
                naming::ruby_inspect_string(&pm.get("ends_on").map(Json::to_s).unwrap_or_default()),
                naming::ruby_inspect_string(&initial_state),
                handler_strs.join(", ")
            )
        })
        .collect();

    exemplar.render(
        "process_manager_table",
        &[
            ("fn tmpl_literal_fns_placeholder() {}", literal_fns.join("\n")),
            (
                "    crate::kernel::ProcessManagerDef { name: \"tmpl_pm_name\", correlates_by: \"tmpl_correlates_by\", starts_on: \"tmpl_starts_on\", ends_on: \"tmpl_ends_on\", initial_state: \"tmpl_initial_state\", handlers: &[] },",
                pm_exprs.iter().map(|e| format!("    {e},")).collect::<Vec<_>>().join("\n"),
            ),
        ],
    )
}

/// `Naming.reference_key(event.aggregate)`, precomputed per aggregate.
pub fn emit_reference_key_table(exemplar: &Exemplar, chapters: &[(String, Vec<String>)]) -> String {
    let arms: Vec<String> = chapters
        .iter()
        .flat_map(|(domain_name, aggregate_names)| {
            aggregate_names.iter().map(move |name| {
                let qualified = format!("{domain_name}::{name}");
                let key = crate::hecks_naming::snake(name);
                format!("        {} => Some({}),", naming::ruby_inspect_string(&qualified), naming::ruby_inspect_string(&key))
            })
        })
        .collect();

    exemplar.render("reference_key_table", &[("\"tmpl_qualified\" => Some(\"tmpl_key\"),", arms.join("\n"))])
}

/// "DOES THIS VERB CREATE THE RECORD IT ADDRESSES" — `orchestrate.rs`'s
/// own routing split (`split_routed_args`) needs this before it can
/// decide whether a policy/saga-triggered dispatch's projected args
/// should have their addressing key promoted into `to:` at all —
/// `rust/project/reactions.rb`'s own `emit_creates_table` header has the
/// full argument. Reuses each aggregate entry's own already-computed
/// `commands[].creates`/`commands[].verb` fields verbatim; an entity
/// command is never creating (commands.rs's own header on
/// `emit_entity_command`), so it always reads `false` without needing
/// its own branch.
pub fn emit_creates_table(exemplar: &Exemplar, aggregates: &[AggregateEntry]) -> String {
    let mut arms: Vec<String> = Vec::new();
    for a in aggregates {
        for c in &a.commands {
            arms.push(format!("        {} => {},", naming::ruby_inspect_string(&c.verb), c.creates));
        }
        for c in &a.entity_commands {
            arms.push(format!("        {} => false,", naming::ruby_inspect_string(&c.verb)));
        }
    }

    exemplar.render("creates_table", &[("\"tmpl_verb\" => true,", arms.join("\n"))])
}

/// THE SINGLE-COMPONENT IDENTITY HEAD `orchestrate.rs`'s own routing
/// split tries first — `rust/project/reactions.rb`'s own `emit_identity_
/// head_table` header has the full argument, including why a COMPOSITE
/// identity is a real, documented gap here rather than silently assumed
/// to work.
pub fn emit_identity_head_table(exemplar: &Exemplar, aggregates: &[AggregateEntry]) -> String {
    let arms: Vec<String> = aggregates
        .iter()
        .filter_map(|a| {
            if a.identified_by.len() != 1 {
                return None;
            }
            let head = a.identified_by[0].split('.').next().unwrap_or(&a.identified_by[0]);
            let qualified = format!("{}::{}", a.domain_name, a.name);
            Some(format!("        {} => Some({}),", naming::ruby_inspect_string(&qualified), naming::ruby_inspect_string(head)))
        })
        .collect();

    exemplar.render("identity_head_table", &[("\"tmpl_qualified\" => Some(\"tmpl_head\"),", arms.join("\n"))])
}

/// Port of `rust/project/reactions.rb`'s own `emit_command_attributes_
/// table` — see that function's own header for the full argument (R1,
/// docs/audits/2026-08-11-bug-triage.md).
pub fn emit_command_attributes_table(exemplar: &Exemplar, aggregates: &[AggregateEntry]) -> String {
    let mut arms: Vec<String> = Vec::new();
    for a in aggregates {
        for c in &a.commands {
            let names = c.attributes.iter().map(|n| naming::ruby_inspect_string(n)).collect::<Vec<_>>().join(", ");
            arms.push(format!("        {} => &[{}],", naming::ruby_inspect_string(&c.verb), names));
        }
        for c in &a.entity_commands {
            let names = c.attributes.iter().map(|n| naming::ruby_inspect_string(n)).collect::<Vec<_>>().join(", ");
            arms.push(format!("        {} => &[{}],", naming::ruby_inspect_string(&c.verb), names));
        }
    }

    exemplar.render("command_attributes_table", &[("\"tmpl_verb\" => &[\"tmpl_attr\"],", arms.join("\n"))])
}

/// `for_each` — THE FAN-OUT'S OWN QUERY, qualified here rather than in
/// the kernel: `Behaviour::Policy#for_each_route` resolves the bare
/// "Aggregate.query" spelling against the policy's own domain, and that
/// resolution is a fact about the source.
fn fan_out_verb_expr(domain_name: &str, policy: &Json) -> String {
    let for_each = policy.get("for_each").map(Json::to_s).unwrap_or_default();
    if for_each.is_empty() {
        return "None".to_string();
    }
    let qualified = if for_each.contains("::") { for_each } else { format!("{domain_name}::{for_each}") };
    format!("Some({})", naming::ruby_inspect_string(&qualified))
}

/// THE NAME A MATCHED ROW'S ID IS MINTED UNDER — the TARGET COMMAND'S
/// question, not the aggregate's. `Behaviour::Command#addressing_key_for`
/// is the rule; this is that rule read off the exported IR, and
/// `spec/codegen_parity_spec.rb` holds it byte-identical to
/// `rust/project/reactions.rb`'s own spelling of the same thing.
fn fan_out_key_expr(policy: &Json, aggregates: &[Json]) -> String {
    let for_each = policy.get("for_each").map(Json::to_s).unwrap_or_default();
    if for_each.is_empty() {
        return "None".to_string();
    }
    let path = for_each.split('.').next().unwrap_or_default().to_string();
    let row_aggregate = path.rsplit("::").next().unwrap_or(&path).to_string();

    let trigger = policy.get("trigger_command").map(Json::to_s).unwrap_or_default();
    let mut parts = trigger.splitn(2, '.');
    let target_aggregate = parts.next().unwrap_or_default().to_string();
    let target_command = parts.next().unwrap_or_default().to_string();

    let key = aggregates
        .iter()
        .find(|a| a.get("name").map(Json::to_s).unwrap_or_default() == target_aggregate)
        .and_then(|a| a.get("commands"))
        .and_then(|commands| match commands {
            Json::Array(items) => items
                .iter()
                .find(|c| c.get("name").map(Json::to_s).unwrap_or_default() == target_command)
                .cloned(),
            _ => None,
        })
        .and_then(|command| addressing_key_for(&command, &row_aggregate));

    match key {
        Some(name) => format!("Some({})", naming::ruby_inspect_string(&name)),
        None => "None".to_string(),
    }
}

fn addressing_key_for(command: &Json, aggregate_name: &str) -> Option<String> {
    if command.get("references").map(Json::to_s).unwrap_or_default() == aggregate_name {
        return Some(crate::hecks_naming::snake(aggregate_name));
    }

    let wanted = format!("Reference<{aggregate_name}>");
    match command.get("attributes") {
        Some(Json::Array(items)) => items
            .iter()
            .find(|a| a.get("type").map(Json::to_s).unwrap_or_default() == wanted)
            .and_then(|a| a.get("name").map(Json::to_s)),
        _ => None,
    }
}

/// `trigger ..., with:` — each binding already rendered on the wire
/// (`Literal::render`, so a Symbol keeps its leading colon).
fn with_spec_expr(policy: &Json) -> String {
    let pairs = match policy.get("with_spec") {
        Some(Json::Array(items)) => items.clone(),
        _ => Vec::new(),
    };
    if pairs.is_empty() {
        return "&[]".to_string();
    }
    let rendered: Vec<String> = pairs
        .iter()
        .filter_map(|pair| match pair {
            Json::Array(kv) if kv.len() == 2 => Some(format!(
                "({}, {})",
                naming::ruby_inspect_string(&kv[0].to_s()),
                naming::ruby_inspect_string(&kv[1].to_s())
            )),
            _ => None,
        })
        .collect();
    format!("&[{}]", rendered.join(", "))
}
