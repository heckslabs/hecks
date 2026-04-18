//! Generator for behavioral test suites
//!
//! Walks a source domain's IR and emits one starter test per command
//! plus one per query. Smart enough that the auto-generated suite
//! mostly *passes* against the in-memory runner — the user iterates
//! from there.
//!
//! How each test is composed:
//!
//! * **Setups.** If the command has a self-ref (a reference whose
//!   target matches its own aggregate), a setup creates the entity
//!   first using the aggregate's first Create-style command. If the
//!   command has cross-refs (references to other aggregates),
//!   setups create those entities first too. The runtime auto-assigns
//!   IDs starting at "1" sequentially, so the setup→input chain works
//!   without naming.
//!
//! * **Input.** Self-ref id (always "1" because we just created it),
//!   cross-ref ids ("1" each), then the command's declared attributes
//!   with sample values per type.
//!
//! * **Expect.** Three sources, merged:
//!     1. For Create-style commands: the command attrs that ALSO appear
//!        as aggregate attrs (the runtime auto-bootstraps these).
//!     2. Each `then_set :field, to: <val>` mutation contributes
//!        `field: <val>`. Each append mutation contributes
//!        `field_size: 1`.
//!     3. If the command appears in a lifecycle transition:
//!        `<lifecycle.field>: <to_state>`.
//!
//! Refused-variant tests for given clauses are NOT auto-generated —
//! they need domain knowledge of what setup makes the given fail.
//! Hand-write those.

use crate::behaviors_ir::TestSuite;
use crate::ir::{Aggregate, Attribute, Command, Domain, MutationOp, Query};
use std::collections::BTreeSet;

/// Generate the full text of a `_behavioral_tests.bluebook` for `source`.
pub fn generate_behaviors(source: &Domain, _archetype: Option<&TestSuite>) -> String {
    let mut out = String::new();
    out.push_str(&format!("Hecks.behaviors {:?} do\n", source.name));
    out.push_str(&format!(
        "  vision \"Behavioral tests for the {} domain — exercises every command and query in memory\"\n\n",
        source.name,
    ));

    // Pre-compute lifecycle transitions per command-name so each test
    // can include its expected to_state without searching every aggregate.
    let lifecycles_by_command = collect_lifecycle_index(source);

    for (i, agg) in source.aggregates.iter().enumerate() {
        if i > 0 { out.push('\n'); }
        out.push_str(&format!(
            "  # ── {} aggregate ──────────────────────────────────────────\n\n",
            agg.name,
        ));

        for cmd in &agg.commands {
            let lifecycle_to = lifecycles_by_command.iter()
                .find(|(name, _, _)| name == &cmd.name)
                .map(|(_, field, to)| (field.clone(), to.clone()));
            out.push_str(&command_test(source, agg, cmd, lifecycle_to));
            out.push('\n');
        }

        for q in &agg.queries {
            out.push_str(&query_test(agg, q));
            out.push('\n');
        }
    }

    out.push_str("end\n");
    out
}

/// One test per command. Composes setup → input → expect from the
/// command's IR, the aggregate's IR, and the lifecycle index.
fn command_test(
    domain: &Domain,
    agg: &Aggregate,
    cmd: &Command,
    lifecycle_to: Option<(String, String)>,
) -> String {
    let self_ref = self_ref_for(agg, cmd);
    let cross_refs = cross_refs_for(agg, cmd);

    let mut setups: Vec<String> = Vec::new();

    // Self-ref → create an entity of the same aggregate first.
    if self_ref.is_some() {
        if let Some(create) = pick_create_command(agg) {
            // Don't recurse: if the create itself has cross-refs,
            // we'd need a deeper plan. Common case is plain Create*.
            setups.push(format!("    setup  {:?}{}",
                create.name, kwargs_inline(create)));
        }
    }

    // Cross-refs → create each referenced aggregate first.
    for cref in &cross_refs {
        if let Some(target_agg) = domain.aggregates.iter().find(|a| a.name == cref.target) {
            if let Some(create) = pick_create_command(target_agg) {
                setups.push(format!("    setup  {:?}{}",
                    create.name, kwargs_inline(create)));
            }
        }
    }

    let input_pairs = build_input(cmd, &self_ref, &cross_refs);
    let expect_pairs = build_expect(agg, cmd, lifecycle_to);

    let mut s = String::new();
    s.push_str(&format!("  test \"{}\" do\n", test_name(cmd, agg)));
    s.push_str(&format!("    tests {:?}, on: {:?}\n", cmd.name, agg.name));
    for setup in &setups { s.push_str(setup); s.push('\n'); }
    if !input_pairs.is_empty() {
        s.push_str(&format!("    input  {}\n", join_kvs(&input_pairs)));
    }
    s.push_str(&format!("    expect {}\n", join_kvs(&expect_pairs)));
    s.push_str("  end\n");
    s
}

fn query_test(agg: &Aggregate, q: &Query) -> String {
    let setup = pick_create_command(agg).map(|c| format!(
        "    setup  {:?}{}\n", c.name, kwargs_inline(c),
    ));
    let mut s = String::new();
    s.push_str(&format!("  test \"{} returns matching records\" do\n", q.name));
    s.push_str(&format!("    tests {:?}, on: {:?}, kind: :query\n", q.name, agg.name));
    if let Some(line) = setup { s.push_str(&line); }
    s.push_str("    expect count: 1\n");
    s.push_str("  end\n");
    s
}

// ─── plan helpers ────────────────────────────────────────────────────

/// Build (cmd_name, lifecycle_field, to_state) tuples for every
/// transition in the source. Looked up by command-name when composing
/// expectations.
fn collect_lifecycle_index(domain: &Domain) -> Vec<(String, String, String)> {
    domain.aggregates.iter()
        .filter_map(|a| a.lifecycle.as_ref().map(|lc| (lc, &a.commands)))
        .flat_map(|(lc, _)| lc.transitions.iter().map(move |t| {
            (t.command.clone(), lc.field.clone(), t.to_state.clone())
        }))
        .collect()
}

/// The command's self-ref name (snake-cased aggregate name) if any
/// reference targets the same aggregate. Mirrors `find_self_ref` in
/// command_dispatch.rs — must agree for setup→input chains to work.
fn self_ref_for(agg: &Aggregate, cmd: &Command) -> Option<String> {
    let agg_snake = to_snake_case(&agg.name);
    for r in &cmd.references {
        let ref_snake = to_snake_case(&r.target);
        if ref_snake == agg_snake || agg_snake.ends_with(&ref_snake) {
            return Some(ref_snake);
        }
    }
    None
}

/// References that point to OTHER aggregates (not self-ref). The
/// runtime stores these as `<ref_name>: <id>` in aggregate state.
fn cross_refs_for<'a>(agg: &Aggregate, cmd: &'a Command) -> Vec<&'a crate::ir::Reference> {
    let agg_snake = to_snake_case(&agg.name);
    cmd.references.iter()
        .filter(|r| {
            let ref_snake = to_snake_case(&r.target);
            !(ref_snake == agg_snake || agg_snake.ends_with(&ref_snake))
        })
        .collect()
}

/// Pick a setup command for `agg`. Preference order:
///   1. Create-style by name (Create*, Place*, Register*, Open*, Add*)
///   2. Any command with no references (treats the aggregate as a
///      singleton and creates id "1" via the runtime's default path)
/// Falls back to None if every command needs a reference — at that
/// point the aggregate has no reachable bootstrap and the auto-gen
/// can't help.
fn pick_create_command(agg: &Aggregate) -> Option<&Command> {
    for prefix in &["Create", "Place", "Register", "Open", "Add"] {
        if let Some(c) = agg.commands.iter().find(|c| c.name.starts_with(prefix)) {
            return Some(c);
        }
    }
    agg.commands.iter().find(|c| c.references.is_empty())
}

/// Inputs for the command under test. Self-ref id first (always "1"),
/// then cross-ref ids (each "1"), then command attrs with sample values.
fn build_input(
    cmd: &Command,
    self_ref: &Option<String>,
    cross_refs: &[&crate::ir::Reference],
) -> Vec<(String, String)> {
    let mut out: Vec<(String, String)> = Vec::new();
    if let Some(name) = self_ref {
        out.push((name.clone(), "1".into()));
    }
    for cref in cross_refs {
        out.push((cref.name.clone(), "1".into()));
    }
    for attr in &cmd.attributes {
        out.push((attr.name.clone(), sample_value(&attr.attr_type)));
    }
    out
}

/// Expectations for the command under test. Three sources merged:
///   - Create-style commands: command attrs that match aggregate attrs.
///   - Each then_set mutation: `field: value` (or `field_size: 1` for append).
///   - Lifecycle transitions: `<field>: <to_state>`.
/// Falls back to `ok: "true"` when nothing else qualifies.
fn build_expect(
    agg: &Aggregate,
    cmd: &Command,
    lifecycle_to: Option<(String, String)>,
) -> Vec<(String, String)> {
    let mut out: Vec<(String, String)> = Vec::new();
    let mut seen: BTreeSet<String> = BTreeSet::new();

    let agg_attr_names: BTreeSet<&str> = agg.attributes.iter()
        .map(|a| a.name.as_str())
        .collect();

    // 1. Create-style: runtime copies matching cmd attrs to aggregate state.
    if is_create_command(cmd) {
        for attr in &cmd.attributes {
            if agg_attr_names.contains(attr.name.as_str()) && seen.insert(attr.name.clone()) {
                out.push((attr.name.clone(), sample_value(&attr.attr_type)));
            }
        }
        // Also: if the aggregate has a lifecycle, the create lands in
        // the lifecycle's default state. Include that expectation.
        if let Some(lc) = &agg.lifecycle {
            if !lc.default.is_empty() && seen.insert(lc.field.clone()) {
                out.push((lc.field.clone(), quote_string(&lc.default)));
            }
        }
    }

    // 2. then_set mutations: assert on the mutated field.
    for m in &cmd.mutations {
        match m.operation {
            MutationOp::Set => {
                // Mutation values can be:
                //   • a quoted string   "planned"  → use as-is
                //   • a number          0          → use as-is
                //   • a symbol          :status    → reference to the
                //     command's :status attribute. Resolve to that
                //     attribute's sample value (matches what the
                //     runtime stores after dispatch).
                let resolved = resolve_mutation_value(&m.value, cmd);
                if seen.insert(m.field.clone()) {
                    out.push((m.field.clone(), resolved));
                }
            }
            MutationOp::Append => {
                let key = format!("{}_size", m.field);
                if seen.insert(key.clone()) {
                    out.push((key, "1".into()));
                }
            }
            MutationOp::Increment | MutationOp::Decrement => {
                if seen.insert(m.field.clone()) {
                    out.push((m.field.clone(), "1".into()));
                }
            }
            MutationOp::Toggle => {
                if seen.insert(m.field.clone()) {
                    out.push((m.field.clone(), "true".into()));
                }
            }
        }
    }

    // 3. Lifecycle transition: assert on the lifecycle field.
    if let Some((field, to_state)) = lifecycle_to {
        // Override any earlier default from #1 — the transition's
        // to_state is more specific than the lifecycle default.
        out.retain(|(k, _)| k != &field);
        out.push((field, quote_string(&to_state)));
    }

    if out.is_empty() {
        out.push(("ok".into(), "\"true\"".into()));
    }
    out
}

// ─── format helpers ──────────────────────────────────────────────────

fn join_kvs(pairs: &[(String, String)]) -> String {
    pairs.iter()
        .map(|(k, v)| format!("{}: {}", k, v))
        .collect::<Vec<_>>()
        .join(", ")
}

/// kwargs prepended with ", " for use after a positional first arg.
fn kwargs_inline(cmd: &Command) -> String {
    if cmd.attributes.is_empty() { return String::new(); }
    let kvs: Vec<(String, String)> = cmd.attributes.iter()
        .map(|a| (a.name.clone(), sample_value(&a.attr_type)))
        .collect();
    format!(", {}", join_kvs(&kvs))
}

/// Reasonable-looking sample for a stub. The author edits these to
/// match real intent — the generator just has to make the file parse.
fn sample_value(t: &str) -> String {
    match t {
        "Integer" => "1".into(),
        "Float"   => "1.0".into(),
        "Boolean" => "\"true\"".into(),
        "String"  => "\"sample\"".into(),
        _         => format!("\"sample_{}\"", t.to_lowercase()),
    }
}

/// Wrap a bare string token in quotes so it parses as a string in
/// the behaviors DSL (which extracts via extract_string).
fn quote_string(s: &str) -> String { format!("{:?}", s) }

/// Resolve a mutation's source-token value into the sample value the
/// runtime would actually store. Strings/numbers come through as-is;
/// `:symbol` is treated as a reference to a command attribute and
/// resolved to that attribute's sample value (matching what the
/// runtime stores when dispatched with synthesized inputs).
fn resolve_mutation_value(raw: &str, cmd: &Command) -> String {
    let trimmed = raw.trim();
    if let Some(attr_name) = trimmed.strip_prefix(':') {
        // Bare symbol → reference to a command attr.
        if let Some(attr) = cmd.attributes.iter().find(|a| a.name == attr_name) {
            return sample_value(&attr.attr_type);
        }
    }
    raw.to_string()
}

fn is_create_command(cmd: &Command) -> bool {
    for prefix in &["Create", "Add", "Place", "Register", "Open"] {
        if cmd.name.starts_with(prefix) { return true; }
    }
    false
}

fn test_name(cmd: &Command, _agg: &Aggregate) -> String {
    if cmd.attributes.is_empty() {
        format!("{} runs", cmd.name)
    } else {
        let attrs: Vec<String> = cmd.attributes.iter()
            .filter(|a| matches!(a.attr_type.as_str(), "String" | "Integer" | "Float" | "Boolean"))
            .map(|a: &Attribute| a.name.clone())
            .collect();
        if attrs.is_empty() {
            format!("{} runs", cmd.name)
        } else {
            format!("{} sets {}", cmd.name, attrs.join(" + "))
        }
    }
}

fn to_snake_case(s: &str) -> String {
    let mut result = String::new();
    for (i, c) in s.chars().enumerate() {
        if c.is_uppercase() && i > 0 { result.push('_'); }
        result.push(c.to_lowercase().next().unwrap_or(c));
    }
    result
}
