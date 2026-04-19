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

/// Outcome of planning a setup chain. The planner can either:
///   * `Chain(...)` — here's an ordered chain of commands that will leave
///     the aggregate in the precondition state (possibly empty).
///   * `Unsatisfiable` — every candidate producer cascades PAST the
///     precondition state via policies, so no setup can stop at the
///     target state. The caller should skip emitting this test entirely;
///     the upstream test that exercises the cascade already covers it.
enum SetupPlan<'a> {
    Chain(Vec<&'a Command>),
    Unsatisfiable,
}

/// One thing the test command requires of the aggregate's state before it
/// can run. Each variant captures a satisfaction strategy the planner
/// knows about — anything we can't fit here we can't auto-setup, and the
/// command's test is skipped.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
enum Precondition {
    /// `field == "value"` (or `:value`, or `true`/`false`).
    /// Satisfied by a Set producer or a lifecycle transition to value.
    Equals(String, String),
    /// `field > N` — satisfied by a producer that lands field at N+1
    /// (or higher), or by running an Increment producer N+1 times.
    GreaterThan(String, i64),
    /// `field >= N` — satisfied by a producer that lands field at N.
    GreaterOrEqual(String, i64),
    /// `field < N` — already true if attribute default < N (Integer
    /// defaults to 0 which is < N for any positive N), otherwise needs
    /// a producer landing the field below N.
    LessThan(String, i64),
    /// `field.size > 0` / `field.any?` — satisfied by running an Append
    /// producer once.
    NonEmptyList(String),
    /// `field.empty?` — satisfied by default (lists start empty); no
    /// chain step needed, but we still record it so collect_preconditions
    /// can mark the precondition met without a producer search.
    EmptyList(String),
}


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

        // Commands that are ONLY triggered via a same-aggregate policy
        // cascade get no isolated test — the upstream command's test
        // already exercises them through the cascade, and an isolated
        // test for them doesn't reflect how they actually run.
        let policy_triggered = collect_policy_only_triggered(source, agg);

        for cmd in &agg.commands {
            if policy_triggered.contains(&cmd.name) { continue; }
            let lifecycle_to = lifecycles_by_command.iter()
                .find(|(name, _, _)| name == &cmd.name)
                .map(|(_, field, to)| (field.clone(), to.clone()));
            // command_test returns None when the test is unsatisfiable
            // (every setup cascades past the required precondition).
            // Skip emission so the suite stays clean.
            if let Some(test) = command_test(source, agg, cmd, lifecycle_to) {
                out.push_str(&test);
                out.push('\n');
            }
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
) -> Option<String> {
    // Skip when ANY given is unparseable. The planner knows how to satisfy
    // a fixed set of patterns (equality, ordered comparisons, list-size
    // checks) via `parse_precondition`; anything else (English-prose
    // givens like "must have elapsed minimum phase duration", domain-
    // specific predicates like "bid exceeds current") needs hand-written
    // setup. Emit nothing for those rather than pollute the suite with
    // tests that error on `given failed: ...`.
    if cmd.givens.iter().any(|g| parse_precondition(&g.expression).is_none()) {
        return None;
    }

    let self_ref = self_ref_for(agg, cmd);
    let cross_refs = cross_refs_for(agg, cmd);

    let mut setups: Vec<String> = Vec::new();

    // Plan a setup chain that satisfies preconditions on the SAME
    // aggregate. Each step is a command on `agg` whose effect moves
    // us closer to the state the test command requires. Returns None
    // when every candidate producer cascades past the precondition
    // state via policies — in that case, skip the test entirely.
    let chain = match plan_setup_chain(domain, agg, cmd, 5, &mut Vec::new()) {
        SetupPlan::Chain(chain) => chain,
        SetupPlan::Unsatisfiable => return None,
    };
    for chain_cmd in &chain {
        setups.push(emit_setup(agg, chain_cmd));
    }

    // If we still need a self-ref (e.g. the chain didn't already
    // create the entity), add a baseline create at the front. A chain
    // command "creates the entity" if it can run without a self-ref —
    // that's how the runtime distinguishes bootstrap from operate-on.
    // (Name-prefix check would miss commands like `Ingest` that boot
    // an aggregate without using a Create/Add/etc. prefix.)
    //
    // The bootstrap fallback may itself have preconditions — plan its
    // own setup chain recursively so we don't insert a bare create that
    // fails its given. If even the create's chain is unsatisfiable, the
    // whole test must be skipped.
    let chain_creates_entity = chain.iter().any(|c| self_ref_for(agg, c).is_none());
    if self_ref.is_some() && !chain_creates_entity {
        if let Some(create) = pick_create_command(agg) {
            let create_chain = match plan_setup_chain(domain, agg, create, 5, &mut Vec::new()) {
                SetupPlan::Chain(c) => c,
                SetupPlan::Unsatisfiable => return None,
            };
            // The chain planner is lenient about missing producers
            // (returns Chain([]) when no producer exists at all). For
            // a bootstrap fallback we want stricter semantics: if any
            // of the create's own preconditions remain unsatisfied
            // after the chain runs, the setup is doomed — skip the
            // test entirely rather than emit a doomed `setup`.
            if !preconditions_covered(agg, create, &create_chain) {
                return None;
            }
            // Build front insertion in correct execution order:
            // chain steps then the create itself.
            let mut prelude: Vec<String> = Vec::new();
            for chain_cmd in &create_chain {
                prelude.push(emit_setup(agg, chain_cmd));
            }
            prelude.push(emit_setup(agg, create));
            // Splice prelude at the front while preserving its order.
            for (i, line) in prelude.into_iter().enumerate() {
                setups.insert(i, line);
            }
        }
    }

    // Cross-refs → create each referenced aggregate first. Same
    // recursive-planning requirement: the cross-ref create command may
    // itself have preconditions that must be satisfied in the TARGET
    // aggregate's context (different repo, different commands).
    for cref in &cross_refs {
        if let Some(target_agg) = domain.aggregates.iter().find(|a| a.name == cref.target) {
            if let Some(create) = pick_create_command(target_agg) {
                let create_chain = match plan_setup_chain(domain, target_agg, create, 5, &mut Vec::new()) {
                    SetupPlan::Chain(c) => c,
                    SetupPlan::Unsatisfiable => return None,
                };
                if !preconditions_covered(target_agg, create, &create_chain) {
                    return None;
                }
                let mut prelude: Vec<String> = Vec::new();
                for chain_cmd in &create_chain {
                    prelude.push(emit_setup(target_agg, chain_cmd));
                }
                prelude.push(emit_setup(target_agg, create));
                for (i, line) in prelude.into_iter().enumerate() {
                    setups.insert(i, line);
                }
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
    Some(s)
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

/// Names of commands on `agg` that are triggered exclusively by a
/// same-aggregate policy cascade. The upstream command's auto-generated
/// test already exercises these via cascade simulation in `build_expect`,
/// so emitting an isolated test for them is redundant — and worse, the
/// isolated test runs the command in a different in-memory state than
/// production (where it only ever runs as part of the upstream cascade).
///
/// "Same-aggregate" matters: cross-aggregate cascades touch a different
/// repo at runtime, and the test runner doesn't auto-fire them anyway.
/// Those commands still need their own isolated tests.
///
/// We also require `cascade_can_dispatch` so the cascade actually fires
/// in the runtime — a triggered command with a self-ref that the upstream
/// can't supply gets silently dropped at dispatch, in which case the
/// upstream test does NOT cover it and we must keep the isolated test.
fn collect_policy_only_triggered(domain: &Domain, agg: &Aggregate) -> BTreeSet<String> {
    // First pass: collect (triggered, upstream) edges where upstream
    // lives on the same aggregate AND the runtime cascade can dispatch.
    // Each such edge is a candidate "skip the triggered command's test".
    let mut edges: Vec<(String, String)> = Vec::new(); // (triggered, upstream)
    for policy in &domain.policies {
        let Some(triggered) = agg.commands.iter()
            .find(|c| c.name == policy.trigger_command)
        else { continue; };
        let Some(upstream) = agg.commands.iter().find(|c| {
            c.emits.as_deref() == Some(policy.on_event.as_str())
        }) else { continue; };
        if !cascade_can_dispatch(agg, upstream, triggered) { continue; }
        edges.push((triggered.name.clone(), upstream.name.clone()));
    }

    // Cycle detection: if Y's only upstream is X, and X's only upstream
    // is Y (or transitively reaches Y), then neither is "downstream-only"
    // — every starting point is upstream of itself. Keeping both tests
    // is the right call. Drop edges whose upstream chain loops back to
    // the triggered command.
    let mut out: BTreeSet<String> = BTreeSet::new();
    for (triggered, _) in &edges {
        if reaches_upstream(triggered, triggered, &edges, &mut Vec::new()) { continue; }
        out.insert(triggered.clone());
    }
    out
}

/// True if `target` appears as an upstream of `from` (transitively) in
/// the policy edge graph. Used to detect cyclic policy chains where
/// neither participant is exclusively downstream.
fn reaches_upstream(
    from: &str,
    target: &str,
    edges: &[(String, String)],
    visited: &mut Vec<String>,
) -> bool {
    if visited.contains(&from.to_string()) { return false; }
    visited.push(from.to_string());
    for (triggered, upstream) in edges {
        if triggered != from { continue; }
        if upstream == target { return true; }
        if reaches_upstream(upstream, target, edges, visited) { return true; }
    }
    false
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
    domain: &'a Domain,
    agg: &'a Aggregate,
    target_cmd: &'a Command,
    depth: usize,
    visited: &mut Vec<&'a str>,
) -> SetupPlan<'a> {
    if depth == 0 { return SetupPlan::Chain(Vec::new()); }
    if visited.contains(&target_cmd.name.as_str()) { return SetupPlan::Chain(Vec::new()); }
    visited.push(target_cmd.name.as_str());
    let mut chain: Vec<&Command> = Vec::new();
    let mut produced: ProducedState = ProducedState::default();
    let mut unsatisfiable = false;

    for pre in collect_preconditions(agg, target_cmd) {
        // Already satisfied by an earlier step in this chain?
        if produced.satisfies(&pre) { continue; }
        // Trivially true by the aggregate's defaults?
        if precondition_default_holds(agg, &pre) { continue; }
        // Pick a producer that, after its full policy cascade, still
        // leaves the aggregate in the precondition state. If a candidate
        // exists but every candidate cascades past the target state, mark
        // the chain unsatisfiable so the test is skipped (the upstream
        // test already exercises the cascade through `target_cmd`).
        match find_producer(domain, agg, &pre) {
            Some(producer) => {
                // Recurse: producer may itself have preconditions.
                let sub_chain = match plan_setup_chain(domain, agg, producer, depth - 1, visited) {
                    SetupPlan::Chain(sub) => sub,
                    SetupPlan::Unsatisfiable => {
                        unsatisfiable = true;
                        break;
                    }
                };
                for sub in sub_chain {
                    if !chain.iter().any(|c| c.name == sub.name) {
                        chain.push(sub);
                        produced.absorb(agg, sub);
                    }
                }
                if !chain.iter().any(|c| c.name == producer.name) {
                    chain.push(producer);
                    produced.absorb(agg, producer);
                }
            }
            None => {
                // Distinguish two cases:
                //   * No producer command exists at all in the bluebook
                //     for this precondition — silently skip (matches the
                //     historical lenient behavior; the test will fail
                //     loudly and the user can fix the bluebook).
                //   * A producer DOES exist but its cascaded final state
                //     lands past the target — mark unsatisfiable.
                if any_producer_exists(agg, &pre) {
                    unsatisfiable = true;
                    break;
                }
            }
        }
    }

    visited.pop();
    if unsatisfiable { SetupPlan::Unsatisfiable } else { SetupPlan::Chain(chain) }
}

/// Track what facts a chain step has produced. Used to short-circuit
/// the planner when a later precondition is already covered by an
/// earlier step's effects, and to feed the satisfiability check.
#[derive(Default)]
struct ProducedState {
    /// (field, value) pairs from then_set or lifecycle transitions.
    set_facts: BTreeSet<(String, String)>,
    /// Field names that received Append in some chain step.
    appended_fields: BTreeSet<String>,
    /// Field names that received Increment in some chain step.
    incremented_fields: BTreeSet<String>,
}

impl ProducedState {
    fn absorb(&mut self, agg: &Aggregate, cmd: &Command) {
        for m in &cmd.mutations {
            let val = m.value.trim_matches('"').to_string();
            match m.operation {
                MutationOp::Set => {
                    self.set_facts.insert((m.field.clone(), val));
                }
                MutationOp::Append => {
                    self.appended_fields.insert(m.field.clone());
                }
                MutationOp::Increment => {
                    self.incremented_fields.insert(m.field.clone());
                }
                MutationOp::Decrement | MutationOp::Toggle => {}
            }
        }
        if let Some(lc) = &agg.lifecycle {
            for t in &lc.transitions {
                if t.command == cmd.name {
                    self.set_facts.insert((lc.field.clone(), t.to_state.clone()));
                }
            }
        }
    }

    fn satisfies(&self, pre: &Precondition) -> bool {
        match pre {
            Precondition::Equals(f, v) => self.set_facts.contains(&(f.clone(), v.clone())),
            Precondition::GreaterThan(f, n) => {
                // A previous chain step set this field to an integer > n,
                // OR there's an Increment on this field AND no Set has
                // reset it to <= n (the chain runs in order).
                self.set_facts.iter().any(|(k, v)| {
                    k == f && v.parse::<i64>().map(|x| x > *n).unwrap_or(false)
                }) || (self.incremented_fields.contains(f)
                    && !self.set_facts.iter().any(|(k, v)| {
                        k == f && v.parse::<i64>().map(|x| x <= *n).unwrap_or(true)
                    }))
            }
            Precondition::GreaterOrEqual(f, n) => {
                self.set_facts.iter().any(|(k, v)| {
                    k == f && v.parse::<i64>().map(|x| x >= *n).unwrap_or(false)
                }) || (self.incremented_fields.contains(f)
                    && !self.set_facts.iter().any(|(k, v)| {
                        k == f && v.parse::<i64>().map(|x| x < *n).unwrap_or(true)
                    }))
            }
            Precondition::LessThan(_, _) => false, // Defaults handle this; chain steps don't.
            Precondition::NonEmptyList(f) => self.appended_fields.contains(f),
            Precondition::EmptyList(_) => true, // Always true by default; chains never violate.
        }
    }
}

/// True when every precondition of `cmd` is satisfied by `chain` (a
/// candidate setup chain) running on top of the aggregate's defaults.
/// Used by the bootstrap-fallback / cross-ref-create paths to detect
/// the case where the planner returned a lenient empty Chain (because
/// no producer exists at all) and warn upstream that the create itself
/// can't actually run — skip the whole test rather than emit a doomed
/// `setup` that fails on its given.
fn preconditions_covered(agg: &Aggregate, cmd: &Command, chain: &[&Command]) -> bool {
    let mut produced = ProducedState::default();
    for c in chain {
        produced.absorb(agg, c);
    }
    collect_preconditions(agg, cmd).iter().all(|pre| {
        precondition_default_holds(agg, pre) || produced.satisfies(pre)
    })
}

/// True when the aggregate's default state already satisfies `pre` —
/// so no setup step is needed. Lifecycle defaults cover Equals(field,
/// default); list attributes start empty so EmptyList is always free;
/// Integer defaults to 0 which makes `field < N` true for any N > 0.
fn precondition_default_holds(agg: &Aggregate, pre: &Precondition) -> bool {
    match pre {
        Precondition::Equals(field, value) => {
            if let Some(lc) = &agg.lifecycle {
                if &lc.field == field && &lc.default == value { return true; }
            }
            // Boolean attribute with explicit default: false / default: true.
            agg.attributes.iter().any(|a| {
                &a.name == field && a.default.as_deref().map(|d| d.trim()) == Some(value.as_str())
            })
        }
        Precondition::EmptyList(field) => {
            // List attributes always start empty in the runtime, so this
            // precondition is trivially satisfied unless the chain has
            // already appended (and it hasn't yet at default time).
            agg.attributes.iter().any(|a| &a.name == field && a.list)
        }
        Precondition::LessThan(field, n) => {
            // Integer fields default to 0 (no explicit default needed).
            // 0 < N for every N > 0, so the precondition trivially holds.
            if *n <= 0 { return false; }
            agg.attributes.iter().any(|a| &a.name == field && a.attr_type == "Integer")
        }
        // > / >= / NonEmptyList never hold by default — need a producer.
        _ => false,
    }
}

/// True if SOME command on `agg` declares an effect that COULD satisfy
/// `pre` — independent of whether that effect survives the policy
/// cascade. Used to distinguish "no producer at all" (lenient skip) from
/// "every producer over-cascades" (mark test unsatisfiable).
fn any_producer_exists(agg: &Aggregate, pre: &Precondition) -> bool {
    match pre {
        Precondition::Equals(field, value) => {
            let by_mutation = agg.commands.iter().any(|c| {
                c.mutations.iter().any(|m| {
                    matches!(m.operation, MutationOp::Set)
                        && &m.field == field
                        && mutation_value_matches(&m.value, value)
                })
            });
            if by_mutation { return true; }
            if let Some(lc) = &agg.lifecycle {
                if &lc.field == field {
                    return lc.transitions.iter().any(|t| &t.to_state == value);
                }
            }
            false
        }
        Precondition::GreaterThan(field, _) | Precondition::GreaterOrEqual(field, _) => {
            agg.commands.iter().any(|c| {
                c.mutations.iter().any(|m| {
                    &m.field == field
                        && matches!(m.operation, MutationOp::Set | MutationOp::Increment)
                })
            })
        }
        Precondition::LessThan(field, _) => {
            agg.commands.iter().any(|c| {
                c.mutations.iter().any(|m| {
                    &m.field == field
                        && matches!(m.operation, MutationOp::Set | MutationOp::Decrement)
                })
            })
        }
        Precondition::NonEmptyList(field) => {
            agg.commands.iter().any(|c| {
                c.mutations.iter().any(|m| {
                    &m.field == field && matches!(m.operation, MutationOp::Append)
                })
            })
        }
        Precondition::EmptyList(_) => true,
    }
}

/// True if a mutation's RHS token (raw from the bluebook source) lands
/// at `value`. Tolerates the three forms a Set mutation might write a
/// string in: bare token (`accepted`), quoted (`"accepted"`), or
/// already-trimmed.
fn mutation_value_matches(raw: &str, value: &str) -> bool {
    raw == value
        || raw == format!("\"{}\"", value)
        || raw.trim_matches('"') == value
}

/// Preconditions on the same aggregate that `cmd` requires. Returns
/// every Precondition the planner knows how to satisfy, deduplicated.
fn collect_preconditions(agg: &Aggregate, cmd: &Command) -> Vec<Precondition> {
    let mut out: Vec<Precondition> = Vec::new();
    let mut seen: BTreeSet<Precondition> = BTreeSet::new();

    // From givens: parse the supported pattern set (equality, inequality,
    // size checks). Unparseable givens cause the whole command_test to
    // bail out earlier — by the time we get here, every given parses.
    for g in &cmd.givens {
        if let Some(pre) = parse_precondition(&g.expression) {
            if seen.insert(pre.clone()) { out.push(pre); }
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
                    let pre = Precondition::Equals(lc.field.clone(), from.clone());
                    if seen.insert(pre.clone()) { out.push(pre); }
                }
            }
        }
    }

    out
}

/// Parse `field == "value"`, `field == :value`, `field == true`,
/// `field == false`, or `field == 42` into (field, stringified value).
/// Returns None for shapes the planner can't reason about (e.g. RHS is
/// another field, like `passcode == stored_passcode`).
fn parse_equality(expr: &str) -> Option<(String, String)> {
    let parts: Vec<&str> = expr.splitn(2, "==").collect();
    if parts.len() != 2 { return None; }
    let field = parts[0].trim().to_string();
    if !is_simple_field(&field) { return None; }
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
    // Boolean literal — runtime stores booleans as Bool(true)/Bool(false)
    // and a then_set with `to: true` produces them. Carry the bare token
    // through so the producer search matches `m.value == "true"`.
    if raw == "true" || raw == "false" {
        return Some((field, raw.to_string()));
    }
    // Integer literal — carry through unquoted so the find_producer
    // mutation match (`m.value == value`) lines up with `then_set :n, to: 5`.
    if raw.parse::<i64>().is_ok() {
        return Some((field, raw.to_string()));
    }
    None
}

/// Parse `field > N`, `field >= N`, `field < N` (RHS must be a bare
/// integer literal). Returns (field, op, n) where op is one of "gt",
/// "gte", "lt". RHS-on-the-left forms (`0 < field`) are not supported.
fn parse_inequality(expr: &str) -> Option<(String, &'static str, i64)> {
    // Order matters: longer ops first so "field >= 0" doesn't get
    // misread as "field > = 0" by the splitn check.
    for (op, tag) in &[(">=", "gte"), ("<=", "lte"), (">", "gt"), ("<", "lt")] {
        if !expr.contains(op) { continue; }
        // For "<" / ">" alone, skip if the longer form is present.
        if *op == ">" && expr.contains(">=") { continue; }
        if *op == "<" && expr.contains("<=") { continue; }
        let parts: Vec<&str> = expr.splitn(2, op).collect();
        if parts.len() != 2 { continue; }
        let field = parts[0].trim().to_string();
        if !is_simple_field(&field) { continue; }
        let raw = parts[1].trim().trim_end_matches('}').trim();
        // Bare integer literal only — `field > other_field` is not
        // satisfiable by the planner (would need symbolic reasoning).
        if let Ok(n) = raw.parse::<i64>() {
            return Some((field, tag, n));
        }
    }
    None
}

/// Parse `field.size > N`, `field.size >= N`, `field.any?`, `field.empty?`
/// into (field, op, n). Op is "gt", "gte", "any", or "empty".
fn parse_size_check(expr: &str) -> Option<(String, &'static str, i64)> {
    let trimmed = expr.trim().trim_end_matches('}').trim();
    if let Some(field) = trimmed.strip_suffix(".any?") {
        let f = field.trim().to_string();
        if !is_simple_field(&f) { return None; }
        return Some((f, "any", 0));
    }
    if let Some(field) = trimmed.strip_suffix(".empty?") {
        let f = field.trim().to_string();
        if !is_simple_field(&f) { return None; }
        return Some((f, "empty", 0));
    }
    // `<field>.size <op> <n>` — reuse the inequality parser by shape.
    let dot = trimmed.find(".size")?;
    let field = trimmed[..dot].trim().to_string();
    if !is_simple_field(&field) { return None; }
    let rest = trimmed[dot + 5..].trim().trim_end_matches('}').trim();
    for (op, tag) in &[(">=", "gte"), ("<=", "lte"), (">", "gt"), ("<", "lt"),
                       ("==", "eq")] {
        if !rest.starts_with(op) { continue; }
        let raw = rest[op.len()..].trim();
        if let Ok(n) = raw.parse::<i64>() {
            return Some((field, tag, n));
        }
    }
    None
}

/// Top-level parser — try every shape the planner knows. Returns None
/// when the given expression doesn't match any supported pattern.
fn parse_precondition(expr: &str) -> Option<Precondition> {
    // Size checks must come BEFORE inequality so `field.size > 0` isn't
    // mis-parsed as `field.size` GT-of-something.
    if let Some((field, op, n)) = parse_size_check(expr) {
        return match op {
            // `size > 0` and `size >= 1` are both "non-empty" — one
            // Append step satisfies them. Larger thresholds (`>= 2`,
            // `> 5`) would need the planner to repeat the Append step
            // N times, which it doesn't do; bail so the test is skipped
            // rather than emitted with an unsatisfied chain.
            "gt"  if n == 0 => Some(Precondition::NonEmptyList(field)),
            "gte" if n == 1 => Some(Precondition::NonEmptyList(field)),
            "any" => Some(Precondition::NonEmptyList(field)),
            "empty" | "eq" if n == 0 => Some(Precondition::EmptyList(field)),
            _ => None, // Other size shapes — not satisfiable in a single step.
        };
    }
    if let Some((field, value)) = parse_equality(expr) {
        return Some(Precondition::Equals(field, value));
    }
    if let Some((field, op, n)) = parse_inequality(expr) {
        return match op {
            "gt"  => Some(Precondition::GreaterThan(field, n)),
            "gte" => Some(Precondition::GreaterOrEqual(field, n)),
            "lt"  => Some(Precondition::LessThan(field, n)),
            // <= isn't in the satisfiable set — too easy to overshoot.
            _ => None,
        };
    }
    None
}

/// True when `s` is a simple bareword field name (alpha/digit/underscore
/// only). Filters out RHS expressions that happen to look like fields.
fn is_simple_field(s: &str) -> bool {
    !s.is_empty() && s.chars().all(|c| c.is_alphanumeric() || c == '_')
}

/// Find a command on `agg` whose effects, after the full policy cascade,
/// satisfy `pre`. Strategy varies by precondition shape:
///   * Equals(f,v)  — Set mutation `to: v` on f, OR lifecycle transition
///     to v on f. Cascade-aware: a candidate that lands at v then emits
///     into a chain that moves f past v is rejected.
///   * GreaterThan(f,n) / GreaterOrEqual(f,n) — Set mutation landing f
///     at an integer ≥ n+1 (or n for >=), OR an Increment mutation on f
///     (treated as "fires once, brings field to 1" — sufficient when n
///     is 0; for larger n the planner doesn't yet replicate the cmd N+1
///     times, but most observed bluebooks gate on > 0).
///   * LessThan(f,n) — Set mutation landing f at an integer < n.
///     Defaults handle the n>0 case before we even get here.
///   * NonEmptyList(f) — Append mutation on f.
///   * EmptyList — never reached (default-satisfied earlier).
///
/// When every candidate over-cascades, returns None and the caller marks
/// the chain unsatisfiable (see `plan_setup_chain`).
fn find_producer<'a>(
    domain: &'a Domain,
    agg: &'a Aggregate,
    pre: &Precondition,
) -> Option<&'a Command> {
    match pre {
        Precondition::Equals(field, value) => find_equals_producer(domain, agg, field, value),
        Precondition::GreaterThan(field, n) => find_int_producer(domain, agg, field, *n + 1, true),
        Precondition::GreaterOrEqual(field, n) => find_int_producer(domain, agg, field, *n, true),
        Precondition::LessThan(field, n) => find_int_producer(domain, agg, field, *n - 1, false),
        Precondition::NonEmptyList(field) => find_append_producer(agg, field),
        Precondition::EmptyList(_) => None,
    }
}

fn find_equals_producer<'a>(
    domain: &'a Domain,
    agg: &'a Aggregate,
    field: &str,
    value: &str,
) -> Option<&'a Command> {
    let satisfies = |c: &&Command| {
        let cascade = simulate_cascade(domain, agg, c);
        cascade.iter().any(|(k, v)| {
            k == field && (v == value || v.trim_matches('"') == value)
        })
    };

    // Mutation match — among commands whose Set mutation targets the
    // field/value, prefer one whose cascade preserves it.
    let by_mutation = agg.commands.iter().filter(|c| {
        c.mutations.iter().any(|m| {
            matches!(m.operation, MutationOp::Set)
                && m.field == field
                && mutation_value_matches(&m.value, value)
        })
    }).find(satisfies);
    if by_mutation.is_some() { return by_mutation; }

    // Lifecycle transition match — same filter.
    if let Some(lc) = &agg.lifecycle {
        if lc.field == field {
            return lc.transitions.iter()
                .filter(|t| t.to_state == value)
                .filter_map(|t| agg.commands.iter().find(|c| c.name == t.command))
                .find(satisfies);
        }
    }

    None
}

/// Find a producer that lands `field` at an integer satisfying the
/// caller's bound. `at_least` chooses the direction: true means the
/// chosen value must be ≥ `target`, false means ≤ `target`.
///
/// Increment producers count as "lands field at >= 1 from default 0",
/// which is sufficient for `field > 0` / `field >= 1` (the common case).
fn find_int_producer<'a>(
    domain: &'a Domain,
    agg: &'a Aggregate,
    field: &str,
    target: i64,
    at_least: bool,
) -> Option<&'a Command> {
    // Direct Set with integer literal.
    let by_set = agg.commands.iter().find(|c| {
        c.mutations.iter().any(|m| {
            if !matches!(m.operation, MutationOp::Set) || m.field != field { return false; }
            let raw = m.value.trim().trim_matches('"');
            let Ok(n) = raw.parse::<i64>() else { return false; };
            if at_least { n >= target } else { n <= target }
        })
    });
    if by_set.is_some() { return by_set; }

    // Increment counts as a "raise it" producer; only useful for at_least
    // bounds where target is small (one increment lands at 1). Reject
    // when target > 1 since the chain only fires the producer once.
    if at_least && target <= 1 {
        let by_inc = agg.commands.iter().find(|c| {
            c.mutations.iter().any(|m| {
                matches!(m.operation, MutationOp::Increment) && m.field == field
            })
        });
        if by_inc.is_some() {
            // Cascade preservation: if the increment producer cascades
            // into a Set that resets the field, the test would fail.
            // simulate_cascade tracks Set/lifecycle only — Increment
            // values aren't predicted, so we accept the producer when
            // the cascade contains no Set on `field` after the increment.
            let cascade = simulate_cascade(domain, agg, by_inc.unwrap());
            let resets = cascade.iter().any(|(k, v)| {
                k == field && v.trim_matches('"') == "0"
            });
            if !resets { return by_inc; }
        }
    }

    // For LessThan with target == 0 we'd need a Decrement producer; not
    // common enough to wire up — return None and the test gets skipped.
    None
}

fn find_append_producer<'a>(agg: &'a Aggregate, field: &str) -> Option<&'a Command> {
    agg.commands.iter().find(|c| {
        c.mutations.iter().any(|m| {
            matches!(m.operation, MutationOp::Append) && m.field == field
        })
    })
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

/// Expectations for the command under test. Three sources merged:
///   - Create-style commands: command attrs that match aggregate attrs.
///   - Append/Toggle mutations: `field_size: 1` / `field: true`.
///   - Cascade simulation: walk emit→policy→trigger, applying Set
///     mutations and lifecycle transitions for `cmd` itself plus every
///     command transitively triggered. Later cascade steps override
///     earlier values (last-write-wins). Same-aggregate only.
/// The lifecycle_to argument is unused — simulate_cascade computes it
/// directly from `cmd`'s lifecycle transition.
/// Falls back to `ok: "true"` when nothing else qualifies.
fn build_expect(
    domain: &Domain,
    agg: &Aggregate,
    cmd: &Command,
    _lifecycle_to: Option<(String, String)>,
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
        // Lifecycle default: only emit if the create command itself has
        // no transition (otherwise the cascade simulator below adds the
        // to_state, which is more specific).
        if let Some(lc) = &agg.lifecycle {
            let has_transition = lc.transitions.iter().any(|t| t.command == cmd.name);
            if !has_transition && !lc.default.is_empty() && seen.insert(lc.field.clone()) {
                out.push((lc.field.clone(), quote_string(&lc.default)));
            }
        }
    }

    // 2. Append/Toggle (skipped by simulate_cascade — counts can't be
    //    safely predicted across cascades, so we only emit them for the
    //    direct command).
    for m in &cmd.mutations {
        match m.operation {
            MutationOp::Append => {
                let key = format!("{}_size", m.field);
                if seen.insert(key.clone()) {
                    out.push((key, "1".into()));
                }
            }
            MutationOp::Toggle => {
                if seen.insert(m.field.clone()) {
                    out.push((m.field.clone(), "true".into()));
                }
            }
            // Set/Increment/Decrement: handled by simulate_cascade or
            // skipped (Increment/Decrement depend on prior state).
            _ => {}
        }
    }

    // 3. Cascade simulation: applies Set mutations and lifecycle
    //    transitions for cmd and every transitively triggered command,
    //    last-write-wins. This is the source of truth for predicted
    //    final state — captures `ProvisionD1 → ApplyMigrations →
    //    DeployWorker → DeployPages` cascading status="ui_live", which
    //    a naive prediction would miss.
    let cascaded = simulate_cascade(domain, agg, cmd);
    for (field, value) in cascaded {
        out.retain(|(k, _)| k != &field);
        out.push((field.clone(), value));
        seen.insert(field);
    }

    if out.is_empty() {
        out.push(("ok".into(), "\"true\"".into()));
    }
    out
}

/// Simulate the full cascade of `cmd` on `agg` — what fields end up at
/// what values after `cmd` runs and every same-aggregate policy chain
/// fires through. Returns ordered (field, value) pairs with later
/// entries overriding earlier ones (last-write-wins; matches runtime).
///
/// Walks Set mutations and lifecycle transitions only; Append/Toggle/
/// Increment/Decrement are skipped because their final values depend on
/// prior state the simulator doesn't track.
///
/// Cycle-safe via a visited-set (a policy graph may be circular).
fn simulate_cascade(
    domain: &Domain,
    agg: &Aggregate,
    cmd: &Command,
) -> Vec<(String, String)> {
    let mut state: Vec<(String, String)> = Vec::new();
    let mut visited: BTreeSet<String> = BTreeSet::new();
    apply_cascade_step(domain, agg, cmd, &mut state, &mut visited);
    state
}

/// One step of the cascade walker — applies `cmd`'s Set mutations and
/// any lifecycle transition that fires for `cmd`, then recurses into
/// every command triggered by `cmd.emits` via a same-aggregate policy.
fn apply_cascade_step(
    domain: &Domain,
    agg: &Aggregate,
    cmd: &Command,
    state: &mut Vec<(String, String)>,
    visited: &mut BTreeSet<String>,
) {
    if !visited.insert(cmd.name.clone()) { return; }

    // Apply this command's Set mutations.
    for m in &cmd.mutations {
        if let MutationOp::Set = m.operation {
            let resolved = resolve_mutation_value(&m.value, cmd);
            state.retain(|(k, _)| k != &m.field);
            state.push((m.field.clone(), resolved));
        }
    }

    // Apply the first lifecycle transition that fires for this command.
    // (Multiple transitions may exist for different from_states; the
    // runtime picks one based on current state. The simulator picks the
    // first as a best-effort prediction.)
    if let Some(lc) = &agg.lifecycle {
        if let Some(t) = lc.transitions.iter().find(|t| t.command == cmd.name) {
            state.retain(|(k, _)| k != &lc.field);
            state.push((lc.field.clone(), quote_string(&t.to_state)));
        }
    }

    // Recurse into commands triggered by this one's event.
    let Some(emitted) = cmd.emits.as_deref() else { return; };
    for policy in &domain.policies {
        if policy.on_event != emitted { continue; }
        // Same-aggregate only — cross-aggregate cascades touch a
        // different repo's state and don't belong here.
        let Some(triggered) = agg.commands.iter()
            .find(|c| c.name == policy.trigger_command)
        else { continue; };
        // Stop if `triggered` would fail to dispatch in the runtime —
        // policies fire but the triggered command's dispatch errors and
        // the cascade silently terminates. A self-ref command needs its
        // id in event.data; the upstream `cmd` only carries the id when
        // it itself has a self-ref to `agg`. Bootstrap triggered commands
        // (Create-style) can self-create, so they're allowed even
        // without an upstream self-ref.
        if !cascade_can_dispatch(agg, cmd, triggered) { continue; }
        apply_cascade_step(domain, agg, triggered, state, visited);
    }
}

/// Mirror of the runtime's command_dispatch gate: would `triggered` (a
/// same-aggregate command fired by `upstream`'s emitted event) dispatch
/// successfully? Returns false when the runtime would silently drop the
/// cascade so the simulator stops predicting past that hop.
///
/// Three ways a triggered command can dispatch from a cascade:
///   * No self-ref → singleton path always works.
///   * Self-ref AND upstream has the SAME self-ref name → the runner
///     injected the id at top level; it propagates verbatim through
///     event.data into the triggered command's attrs.
///   * Self-ref AND triggered is Create-style → can self-bootstrap.
///
/// Otherwise the runtime errors with MissingAttribute("self-referencing
/// id"), drain_policies silently swallows it, and any state mutations
/// downstream don't happen.
fn cascade_can_dispatch(agg: &Aggregate, upstream: &Command, triggered: &Command) -> bool {
    let Some(triggered_ref) = self_ref_for(agg, triggered) else { return true; };
    if let Some(upstream_ref) = self_ref_for(agg, upstream) {
        if upstream_ref == triggered_ref { return true; }
    }
    let prefixes = ["Create", "Add", "Place", "Register", "Open"];
    prefixes.iter().any(|p| triggered.name.starts_with(p))
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
