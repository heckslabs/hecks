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
use crate::ir::{Aggregate, Attribute, Command, Domain, MutationOp, Query, Transition};
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
/// command's IR, the aggregate's IR, and the lifecycle index. Setup
/// chains follow `given` preconditions and lifecycle from_states
/// recursively (depth-capped) so a test for a command guarded by
/// `given { status == "executed" }` first runs the command that
/// transitions to "executed".
fn command_test(
    domain: &Domain,
    agg: &Aggregate,
    cmd: &Command,
    lifecycle_to: Option<(String, String)>,
) -> String {
    let self_ref = self_ref_for(agg, cmd);
    let cross_refs = cross_refs_for(agg, cmd);

    let mut setups: Vec<String> = Vec::new();

    // Plan a setup chain that satisfies preconditions on the SAME
    // aggregate. Each step is a command on `agg` whose effect moves
    // us closer to the state the test command requires.
    let chain = plan_setup_chain(agg, cmd, 5, &mut Vec::new());
    for chain_cmd in &chain {
        setups.push(emit_setup(agg, chain_cmd));
    }

    // If we still need a self-ref (e.g. the chain didn't already
    // create the entity), add a baseline create at the front. A chain
    // command "creates the entity" if it can run without a self-ref —
    // that's how the runtime distinguishes bootstrap from operate-on.
    // (Name-prefix check would miss commands like `Ingest` that boot
    // an aggregate without using a Create/Add/etc. prefix.)
    let chain_creates_entity = chain.iter().any(|c| self_ref_for(agg, c).is_none());
    if self_ref.is_some() && !chain_creates_entity {
        if let Some(create) = pick_create_command(agg) {
            setups.insert(0, emit_setup(agg, create));
        }
    }

    // Cross-refs → create each referenced aggregate first.
    for cref in &cross_refs {
        if let Some(target_agg) = domain.aggregates.iter().find(|a| a.name == cref.target) {
            if let Some(create) = pick_create_command(target_agg) {
                setups.insert(0, emit_setup(target_agg, create));
            }
        }
    }

    let input_pairs = build_input(cmd, &self_ref, &cross_refs);
    let expect_pairs = build_expect(domain, agg, cmd, lifecycle_to);

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
            // Use r.name (which honors `role: :alias`) so this matches
            // command_dispatch::find_self_ref. Both must agree on the
            // kwarg name the runner injects from in_scope.
            return Some(r.name.clone());
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
///   1. A bootstrap-verb command (Create/Define/Place/Register/Open/
///      Plan/Spawn/Boot/Start) WITH NO references — this is the cleanest
///      "make a fresh instance" signal.
///   2. Any command with no references (treats the aggregate as a
///      singleton and creates id "1" via the runtime's default path).
/// Falls back to None if every command needs a reference — at that
/// point the aggregate has no in-bluebook bootstrap and auto-gen
/// can't help (the user needs to add a Create command, or the test
/// must seed via fixtures).
///
/// Note: "Add" is intentionally NOT a bootstrap prefix here. `AddTopping`
/// adds to an existing pizza; it's not a create. Same for `AddRule`,
/// `AddComponent`, etc. The runtime treats them as create when no
/// self-ref id is given, but for setups we want the unambiguous
/// bootstrap command.
fn pick_create_command(agg: &Aggregate) -> Option<&Command> {
    // A bootstrap command must not have a self-ref (otherwise it
    // requires an existing entity to operate on). Cross-refs are
    // fine — the runner resolves them from in_scope at dispatch.
    let is_bootstrap = |c: &&Command| self_ref_for(agg, c).is_none();

    let prefixes = ["Create", "Define", "Place", "Register", "Open",
                    "Plan", "Spawn", "Boot", "Start", "Initialize",
                    "Seed", "Provision", "Issue"];
    for prefix in &prefixes {
        if let Some(c) = agg.commands.iter()
            .find(|c| c.name.starts_with(prefix) && is_bootstrap(c))
        {
            return Some(c);
        }
    }
    agg.commands.iter().find(is_bootstrap)
}

/// Plan a chain of commands that puts `agg` into the state `target_cmd`
/// requires. Preconditions come from two sources:
///   • `target_cmd.givens` — equality predicates like `status == "X"`
///   • The aggregate's lifecycle — if `target_cmd` is a transition
///     with from_state ≠ default, we need to be in from_state.
///
/// For each precondition, find a command that produces it (then_set
/// or transition to that value), recurse on its preconditions, then
/// emit the chain in correct order.
///
/// Returns commands in execution order. Empty when no preconditions
/// are unmet OR when no producing command exists (the test will
/// surface a real gap to the user).
///
/// `depth` budgets recursion. `visited` carries (cmd_name) to prevent
/// cycles when commands mutually depend.
fn plan_setup_chain<'a>(
    agg: &'a Aggregate,
    target_cmd: &'a Command,
    depth: usize,
    visited: &mut Vec<&'a str>,
) -> Vec<&'a Command> {
    if depth == 0 { return Vec::new(); }
    if visited.contains(&target_cmd.name.as_str()) { return Vec::new(); }
    visited.push(target_cmd.name.as_str());
    let mut chain: Vec<&Command> = Vec::new();
    let mut produced: BTreeSet<(String, String)> = BTreeSet::new();

    for (field, value) in collect_preconditions(agg, target_cmd) {
        // Already satisfied by an earlier step in this chain?
        if produced.contains(&(field.clone(), value.clone())) { continue; }
        // Lifecycle default makes some preconditions trivially true.
        if let Some(lc) = &agg.lifecycle {
            if lc.field == field && lc.default == value { continue; }
        }
        let Some(producer) = find_producer(agg, &field, &value) else { continue; };
        // Recurse: producer may itself have preconditions.
        let sub_chain = plan_setup_chain(agg, producer, depth - 1, visited);
        for sub in sub_chain {
            if !chain.iter().any(|c| c.name == sub.name) {
                chain.push(sub);
                track_produced(agg, sub, &mut produced);
            }
        }
        if !chain.iter().any(|c| c.name == producer.name) {
            chain.push(producer);
            track_produced(agg, producer, &mut produced);
        }
    }

    visited.pop();
    chain
}

/// Equality preconditions on the same aggregate that `cmd` requires.
/// Returns (field, expected_value) pairs, deduplicated.
fn collect_preconditions(agg: &Aggregate, cmd: &Command) -> Vec<(String, String)> {
    let mut out: Vec<(String, String)> = Vec::new();
    let mut seen: BTreeSet<(String, String)> = BTreeSet::new();

    // From givens: parse `<field> == "<value>"` patterns.
    for g in &cmd.givens {
        if let Some(pair) = parse_equality(&g.expression) {
            if seen.insert(pair.clone()) { out.push(pair); }
        }
    }

    // From lifecycle transitions involving this command. A command can
    // have multiple transitions (e.g. one from null, one from
    // "reversed"). If ANY transition has no from_state, the command
    // can fire from default — no precondition needed. Only require
    // from_state when EVERY transition for this command requires one,
    // and then take the first from_state as the satisfiable choice.
    if let Some(lc) = &agg.lifecycle {
        let cmd_transitions: Vec<&Transition> = lc.transitions.iter()
            .filter(|t| t.command == cmd.name)
            .collect();
        if !cmd_transitions.is_empty()
            && cmd_transitions.iter().all(|t| t.from_state.is_some())
        {
            if let Some(t) = cmd_transitions.first() {
                if let Some(from) = &t.from_state {
                    let pair = (lc.field.clone(), from.clone());
                    if seen.insert(pair.clone()) { out.push(pair); }
                }
            }
        }
    }

    out
}

/// Parse `field == "value"` (or `field == :value`) into (field, value).
/// Returns None for shapes the planner can't reason about.
fn parse_equality(expr: &str) -> Option<(String, String)> {
    let parts: Vec<&str> = expr.splitn(2, "==").collect();
    if parts.len() != 2 { return None; }
    let field = parts[0].trim().to_string();
    if field.is_empty() || !field.chars().all(|c| c.is_alphanumeric() || c == '_') {
        return None;
    }
    let raw = parts[1].trim().trim_end_matches('}').trim();
    // Quoted string
    if raw.starts_with('"') {
        let end = raw[1..].find('"')? + 1;
        return Some((field, raw[1..end].to_string()));
    }
    // Bare symbol :value
    if let Some(sym) = raw.strip_prefix(':') {
        let end = sym.find(|c: char| !c.is_alphanumeric() && c != '_')
            .unwrap_or(sym.len());
        return Some((field, sym[..end].to_string()));
    }
    None
}

/// Find a command on `agg` that puts `field` to `value`. Two sources:
///   • a then_set mutation `to: "value"` on this field
///   • a lifecycle transition with this field's to_state == value
fn find_producer<'a>(agg: &'a Aggregate, field: &str, value: &str) -> Option<&'a Command> {
    // Mutation match
    let by_mutation = agg.commands.iter().find(|c| {
        c.mutations.iter().any(|m| {
            matches!(m.operation, MutationOp::Set)
                && m.field == field
                && (m.value == value
                    || m.value == format!("\"{}\"", value)
                    || m.value.trim_matches('"') == value)
        })
    });
    if by_mutation.is_some() { return by_mutation; }

    // Lifecycle transition match
    if let Some(lc) = &agg.lifecycle {
        if lc.field == field {
            if let Some(t) = lc.transitions.iter().find(|t| t.to_state == value) {
                return agg.commands.iter().find(|c| c.name == t.command);
            }
        }
    }

    None
}

/// Track what fields a command produces (after it runs successfully).
fn track_produced(agg: &Aggregate, cmd: &Command, produced: &mut BTreeSet<(String, String)>) {
    for m in &cmd.mutations {
        if let MutationOp::Set = m.operation {
            let val = m.value.trim_matches('"').to_string();
            produced.insert((m.field.clone(), val));
        }
    }
    if let Some(lc) = &agg.lifecycle {
        for t in &lc.transitions {
            if t.command == cmd.name {
                produced.insert((lc.field.clone(), t.to_state.clone()));
            }
        }
    }
}

/// Emit a single setup line for a command on `agg`. Reference kwargs
/// are NOT emitted — the runner injects them from its in-scope map
/// at dispatch time. Bluebook layer stays id-free.
fn emit_setup(_agg: &Aggregate, cmd: &Command) -> String {
    let pairs: Vec<(String, String)> = cmd.attributes.iter()
        .map(|attr| (attr.name.clone(), sample_value(&attr.attr_type)))
        .collect();
    let kvs = if pairs.is_empty() { String::new() } else { format!(", {}", join_kvs(&pairs)) };
    format!("    setup  {:?}{}", cmd.name, kvs)
}

/// Inputs for the command under test. References are NOT emitted here:
/// the bluebook layer is reference-only (no ids), and the test runner
/// resolves references from its in-scope aggregate map at dispatch
/// time. The user just types domain-meaningful kwargs.
fn build_input(
    cmd: &Command,
    _self_ref: &Option<String>,
    _cross_refs: &[&crate::ir::Reference],
) -> Vec<(String, String)> {
    cmd.attributes.iter()
        .map(|attr| (attr.name.clone(), sample_value(&attr.attr_type)))
        .collect()
}

/// Expectations for the command under test. Four sources merged:
///   - Create-style commands: command attrs that match aggregate attrs.
///   - Each then_set mutation: `field: value` (or `field_size: 1` for append).
///   - Cascaded mutations: when a command's emitted event triggers a policy
///     that fires another command on the SAME aggregate, that command's
///     Set mutations override earlier values (later wins). Walks the
///     emit→policy→trigger graph with cycle detection.
///   - Lifecycle transitions: `<field>: <to_state>` (most specific, wins).
/// Falls back to `ok: "true"` when nothing else qualifies.
fn build_expect(
    domain: &Domain,
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
                // Skipping: the resulting count depends on prior state
                // (was the field 0? null? has setup already incremented?).
                // The runner can't predict it; the generator picking "1"
                // produces brittle expectations like "expected 1, got -1"
                // for decrement-from-null. Author writes these by hand.
            }
            MutationOp::Toggle => {
                if seen.insert(m.field.clone()) {
                    out.push((m.field.clone(), "true".into()));
                }
            }
        }
    }

    // 2b. Cascade: walk emit→policy→trigger and let triggered commands'
    //     Set mutations override earlier values. Same-aggregate only —
    //     cross-aggregate cascades land in a different repo's state.
    let mut visited: BTreeSet<String> = BTreeSet::new();
    visited.insert(cmd.name.clone());
    cascade_mutations(domain, agg, cmd, &mut visited, &mut out, &mut seen);

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

/// Walk emit→policy→trigger from `cmd`, applying triggered commands'
/// Set mutations on top of `out` (later wins). Same-aggregate only:
/// cross-aggregate cascades touch a different repo's state and don't
/// belong in this aggregate's expectations.
///
/// Gate: only follow a triggered command if the upstream command's
/// emitted event would carry the references the triggered command
/// requires. Concretely: the upstream `cmd` must reference its own
/// aggregate (so its event.data includes a `:<agg>` key the runtime
/// can use to resolve the triggered command's self-ref). Bootstrap
/// commands (no self-ref) emit events with no aggregate id; the
/// runtime drops the cascade silently when the triggered command
/// fails to dispatch, so the generator must mirror that and stop
/// predicting at this hop.
///
/// `visited` cycle-breaks the recursion (a policy graph may be circular).
fn cascade_mutations(
    domain: &Domain,
    agg: &Aggregate,
    cmd: &Command,
    visited: &mut BTreeSet<String>,
    out: &mut Vec<(String, String)>,
    seen: &mut BTreeSet<String>,
) {
    let Some(emitted) = cmd.emits.as_deref() else { return; };
    // The cascade only carries forward when the upstream command's
    // event payload includes a self-ref to `agg` — that's the id the
    // triggered command needs to resolve its own self-ref. If the
    // upstream is a bootstrap (no self-ref on agg), the runtime
    // policy fires but the triggered command errors and is silently
    // dropped — so don't predict cascaded state past that point.
    if self_ref_for(agg, cmd).is_none() {
        return;
    }
    for policy in &domain.policies {
        if policy.on_event != emitted { continue; }
        // Same-aggregate only — find the triggered command on `agg`.
        let Some(triggered) = agg.commands.iter()
            .find(|c| c.name == policy.trigger_command)
        else { continue; };
        if visited.contains(&triggered.name) { continue; }
        visited.insert(triggered.name.clone());

        for m in &triggered.mutations {
            if let MutationOp::Set = m.operation {
                let resolved = resolve_mutation_value(&m.value, triggered);
                // Cascade overrides: drop any earlier entry for this
                // field, then push the new value at the end.
                out.retain(|(k, _)| k != &m.field);
                out.push((m.field.clone(), resolved));
                seen.insert(m.field.clone());
            }
        }

        // Recurse — the triggered command may itself emit and cascade.
        cascade_mutations(domain, agg, triggered, visited, out, seen);
    }
}

// ─── format helpers ──────────────────────────────────────────────────

fn join_kvs(pairs: &[(String, String)]) -> String {
    pairs.iter()
        .map(|(k, v)| format!("{}: {}", k, v))
        .collect::<Vec<_>>()
        .join(", ")
}

/// kwargs prepended with ", " for use after a positional first arg.
/// Domain attrs only — references are injected by the runner from
/// its in-scope map, never typed in the test source.
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
/// `:symbol` is treated as a reference to either a command attribute
/// (resolved to its sample value) or a command reference (resolved to
/// the cross-ref id "1" — same id the synthesized input passes).
fn resolve_mutation_value(raw: &str, cmd: &Command) -> String {
    let trimmed = raw.trim();
    if let Some(name) = trimmed.strip_prefix(':') {
        if let Some(attr) = cmd.attributes.iter().find(|a| a.name == name) {
            return sample_value(&attr.attr_type);
        }
        // Reference (cross-ref or self-ref): synthesized input passes
        // "1" for every reference; the runtime stores that id on the
        // aggregate's <ref_name> field.
        if cmd.references.iter().any(|r| r.name == name) {
            return "1".into();
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
