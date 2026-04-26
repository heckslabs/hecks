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
use crate::cascade;
use crate::ir::{Aggregate, Attribute, Command, Domain, MutationOp, Query, Transition};
use std::collections::{BTreeMap, BTreeSet};

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
    /// `field.size >= N` (N ≥ 2) or `field.size > N` (N ≥ 1) — satisfied by
    /// running an Append producer N times. The i64 is the MINIMUM size
    /// that satisfies: `size >= 3` carries 3; `size > 2` also carries 3.
    /// In the chain planner the Append producer appears N times in the
    /// chain, and the existing-instance count is subtracted so an already-
    /// seeded chain doesn't double-seed. (i4 gap 7.)
    MinSizeList(String, i64),
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

    // Emit validator warnings for dangling gate flags (i4 gap 4): a
    // `Boolean` attribute with `default: false` that no command ever
    // flips is an inert gate — no reachable state ever turns it true,
    // so every given predicated on it is permanently refused. Surface
    // this as a suite-level comment so `hecks-life conceive-behaviors`
    // (which prints the file) makes the problem visible on regeneration.
    // [antibody-exempt: conceiver fix per i4 gap 4; retires when conceivers port to a bluebook-dispatched form]
    let gate_flag_warnings = detect_dangling_gate_flags(source);
    for (agg_name, attr_name) in &gate_flag_warnings {
        out.push_str(&format!(
            "  # ⚠ gate-flag :{} on {} has no flipper — add a command that `then_set :{}, to: true`, or mark it read-only\n",
            attr_name, agg_name, attr_name,
        ));
    }
    if !gate_flag_warnings.is_empty() {
        out.push('\n');
    }

    // Pre-compute lifecycle transitions per command-name so each test
    // can include its expected to_state without searching every aggregate.
    let lifecycles_by_command = collect_lifecycle_index(source);

    for (i, agg) in source.aggregates.iter().enumerate() {
        if i > 0 { out.push('\n'); }
        out.push_str(&format!(
            "  # ── {} aggregate ──────────────────────────────────────────\n\n",
            agg.name,
        ));

        // Every command gets an isolated test now — mid-pipeline commands
        // aren't redundant when the upstream test asserts the cascade via
        // `expect emits: [...]`. If the bluebook later drops a policy edge
        // or rewires a trigger, both the upstream's emits assertion AND
        // the downstream's isolated test surface the regression.

        for cmd in &agg.commands {
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
            // Cascade lockdown — separate test asserting the static
            // emit→policy→trigger walk. Emitted only when the command
            // has a cascade (otherwise there's nothing to lock).
            let events = cascade::cascade_emits(source, &cmd.name);
            if events.len() > 1 {
                if let Some(cascade_test) = emit_cascade_test(source, agg, cmd, &events) {
                    out.push_str(&cascade_test);
                    out.push('\n');
                }
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

/// Emit a separate cascade-lockdown test for a command whose emit
/// fires a policy chain. Uses `kind: :cascade` so the runner dispatches
/// with cascades ON (regular dispatch path); the only assertion is
/// `expect emits: [E1, E2, ...]`. Drift in the policy graph (added
/// or removed policy, retargeted trigger) changes `cascade_emits`
/// output and breaks this test — exactly the lockdown we want.
fn emit_cascade_test(
    domain: &Domain,
    agg: &Aggregate,
    cmd: &Command,
    events: &[String],
) -> Option<String> {
    // Reuse the regular setup planning so the cascade test starts in
    // the same satisfied precondition state as the state test.
    let chain = match plan_setup_chain(domain, agg, cmd, 5, &mut Vec::new()) {
        SetupPlan::Chain(chain) => chain,
        SetupPlan::Unsatisfiable => return None,
    };
    let self_ref = self_ref_for(agg, cmd);
    let cross_refs = cross_refs_for(agg, cmd);

    // Setups must preserve dependency order: prerequisites BEFORE the
    // commands that consume them. We accumulate prerequisites into a
    // separate `prerequisites` vec and concatenate `prerequisites + chain`
    // at the end. Each helper that adds a prerequisite uses `push` (not
    // `insert(0, ...)`), so chain order is preserved within each phase.
    let mut prerequisites: Vec<String> = Vec::new();
    let chain_creates_entity = chain.iter().any(|c| self_ref_for(agg, c).is_none());
    if self_ref.is_some() && !chain_creates_entity {
        if let Some(create) = pick_create_command(agg) {
            let create_chain = match plan_setup_chain(domain, agg, create, 5, &mut Vec::new()) {
                SetupPlan::Chain(c) => c,
                SetupPlan::Unsatisfiable => return None,
            };
            // Create command first, then its dependency chain, then the
            // existing setups. plan_setup_chain returns prerequisites of
            // the create — those run BEFORE the create itself does not
            // make sense; the chain of a Create command is empty in
            // practice, so the order here only matters for completeness.
            prerequisites.push(emit_setup(agg, create));
            for cc in create_chain { prerequisites.push(emit_setup(agg, cc)); }
        }
    }
    // Cascade tests need every aggregate the cascade will hop through to
    // exist before dispatch — direct cross-refs aren't enough. Walk the
    // static cascade and gather every aggregate any triggered command
    // references; pick a safe bootstrap for each (deduped, in dependency
    // order).
    //
    // "Safe" means: the picked command isn't itself a cascade-triggered
    // command that carries a lifecycle transition. Pre-running such a
    // command would advance the target aggregate past the `from_state`
    // its cascade-hop expects, so the cascade's own dispatch is refused.
    // (i4 gap 6 — CloudflareDeploy's Deployment aggregate had ProvisionD1
    // picked as bootstrap, pre-advancing state to "provisioned" before
    // the cascade's ProvisionD1 could transition from "pending".)
    // [antibody-exempt: fixing the behaviors conceiver per i4 gaps 6+7; retires when conceivers port to a bluebook-dispatched form]
    let cascade_aggs = aggregates_touched_by_cascade(domain, cmd, agg);
    let triggered_in_cascade = commands_triggered_by_cascade(domain, cmd);
    for target_agg_name in &cascade_aggs {
        // Skip the test's own aggregate — its create is already handled.
        if target_agg_name == &agg.name { continue; }
        if let Some(target_agg) = domain.aggregates.iter().find(|a| &a.name == target_agg_name) {
            if let Some(create) = pick_safe_bootstrap(target_agg, &triggered_in_cascade) {
                prerequisites.push(emit_setup(target_agg, create));
            }
            // else: no safe bootstrap exists — skip. The runtime
            // auto-creates singletons on first dispatch, so the cascade
            // handles creation when its own trigger fires.
        }
    }

    // Then, for each cross-aggregate, chain through any preconditions the
    // cascade-triggered commands need that the cascade WON'T satisfy.
    // `plan_setup_chain_filtered` skips producers that would pre-advance
    // a cascade-triggered lifecycle transition — e.g. in restaurant_
    // reservations, the precondition `status == "waiting"` on NotifyParty
    // is satisfied by AddToWaitlist, which IS cascade-triggered but has
    // no lifecycle transition, so it's safe to pre-run. In CloudflareDeploy
    // the precondition on MarkLive (state=="ui_live") is produced by
    // DeployPages, which is cascade-triggered AND a lifecycle transition,
    // so the chain leaves it to the cascade. (i4 gap 6.)
    // [antibody-exempt: fixing the behaviors conceiver per i4 gaps 6+7; retires when conceivers port to a bluebook-dispatched form]
    for target_agg_name in &cascade_aggs {
        if target_agg_name == &agg.name { continue; }
        let Some(target_agg) = domain.aggregates.iter().find(|a| &a.name == target_agg_name) else { continue };
        for triggered_name in &triggered_in_cascade {
            let Some(triggered) = target_agg.commands.iter().find(|c| &c.name == triggered_name) else { continue };
            let chain = match plan_setup_chain_filtered(domain, target_agg, triggered, 5, &mut Vec::new(), &triggered_in_cascade) {
                SetupPlan::Chain(c) => c,
                SetupPlan::Unsatisfiable => continue,
            };
            for step in chain {
                let setup_line = emit_setup(target_agg, step);
                let key = format!("setup  {:?}", step.name);
                if !prerequisites.iter().any(|s| s.contains(&key)) {
                    prerequisites.push(setup_line);
                }
            }
        }
    }
    for cref in &cross_refs {
        if let Some(target_agg) = domain.aggregates.iter().find(|a| a.name == cref.target) {
            if let Some(create) = pick_create_command(target_agg) {
                let setup_for = format!("    setup  {:?}", create.name);
                if !prerequisites.iter().any(|s| s.starts_with(&setup_for)) {
                    prerequisites.push(emit_setup(target_agg, create));
                }
            }
        }
    }

    // Concatenate: prerequisites first (in push order — Creates before
    // dependent transitions), then the test command's own setup chain.
    let mut setups: Vec<String> = prerequisites;
    for c in &chain { setups.push(emit_setup(agg, c)); }

    let input_pairs = build_input(cmd, &self_ref, &cross_refs);
    let quoted: Vec<String> = events.iter().map(|e| format!("\"{}\"", e)).collect();

    let mut s = String::new();
    s.push_str(&format!("  test \"{} cascades through policy chain\" do\n", cmd.name));
    s.push_str(&format!("    tests {:?}, on: {:?}, kind: :cascade\n", cmd.name, agg.name));
    for setup in &setups { s.push_str(setup); s.push('\n'); }
    if !input_pairs.is_empty() {
        s.push_str(&format!("    input  {}\n", join_kvs(&input_pairs)));
    }
    s.push_str(&format!("    expect emits: [{}]\n", quoted.join(", ")));
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

/// Detect Boolean gate flags that no command can flip. A gate flag is a
/// Boolean attribute whose default is literal `false` — the modeler's
/// intent is clearly "starts closed, open later". If no command on the
/// aggregate declares a Set/Toggle mutation on that attribute, the flag
/// is inert: every given predicated on it is permanently refused.
/// Returns (aggregate_name, attribute_name) pairs in source order.
///
/// `default: true` flags are NOT flagged — they start open, so the
/// absence of a writer means "no one ever closes it", which is a
/// different (and less common) shape. Non-Boolean attributes are not
/// flagged because they have many legitimate shapes (ids, notes, etc.)
/// that don't need flippers. (i4 gap 4.)
pub fn detect_dangling_gate_flags(domain: &Domain) -> Vec<(String, String)> {
    let mut out: Vec<(String, String)> = Vec::new();
    for agg in &domain.aggregates {
        for attr in &agg.attributes {
            if !is_gate_flag(attr) { continue; }
            let has_writer = agg.commands.iter().any(|c| {
                c.mutations.iter().any(|m| {
                    matches!(m.operation, MutationOp::Set | MutationOp::Toggle)
                        && m.field == attr.name
                })
            });
            if !has_writer {
                out.push((agg.name.clone(), attr.name.clone()));
            }
        }
    }
    out
}

/// True when `attr` declares `Boolean` with an explicit `default: false`.
/// The type check keeps the warning narrow — an untyped attribute with
/// `default: false` is rarer and might mean something else in future
/// grammar extensions.
fn is_gate_flag(attr: &Attribute) -> bool {
    attr.attr_type == "Boolean"
        && attr.default.as_deref().map(str::trim) == Some("false")
}

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

/// Pick a bootstrap command for `agg` that's safe as a cascade-test
/// pre-setup: not a cascade-triggered command that ALSO carries a
/// lifecycle transition. Pre-running such a command advances the
/// aggregate past the from_state its cascade-hop expects, refusing the
/// cascade's own dispatch. Returns None when only unsafe bootstraps
/// exist; the runtime then auto-creates the singleton on first cascade
/// dispatch, which correctly starts at default lifecycle state.
///
/// Example (CloudflareDeploy): the Deployment aggregate's only non-
/// self-ref commands are the cascade-triggered `ProvisionD1`, `Apply-
/// Migrations`, `DeployWorker`, `DeployPages`. All carry lifecycle
/// transitions, so this returns None — the cascade itself bootstraps
/// Deployment at "pending" via its own ProvisionD1 dispatch.
///
/// Counter-example (Console): the Speaker aggregate's bootstrap
/// `TalkWith` IS a lifecycle transition ("none" → "active") but is
/// NOT cascade-triggered by `RecordMessage`. Picking it is fine:
/// pre-running advances Speaker past default, but `LearnAboutSpeaker`
/// (the cascade-triggered Speaker command) has no from_state gate, so
/// it dispatches cleanly. (i4 gap 6.)
fn pick_safe_bootstrap<'a>(
    agg: &'a Aggregate,
    triggered_in_cascade: &BTreeSet<String>,
) -> Option<&'a Command> {
    let is_bootstrap = |c: &&Command| self_ref_for(agg, c).is_none();
    let is_safe = |c: &&Command| -> bool {
        if !triggered_in_cascade.contains(&c.name) { return true; }
        if let Some(lc) = &agg.lifecycle {
            return !lc.transitions.iter().any(|t| t.command == c.name);
        }
        true
    };

    let prefixes = ["Create", "Define", "Place", "Register", "Open",
                    "Plan", "Spawn", "Boot", "Start", "Initialize",
                    "Seed", "Provision", "Issue"];
    for prefix in &prefixes {
        if let Some(c) = agg.commands.iter()
            .find(|c| c.name.starts_with(prefix) && is_bootstrap(c) && is_safe(c))
        {
            return Some(c);
        }
    }
    agg.commands.iter().find(|c| is_bootstrap(c) && is_safe(c))
}

/// Collect every command name that will be dispatched by the cascade
/// rooted at `cmd` (following emit → policy → trigger edges). Used by
/// `pick_safe_bootstrap` and `plan_setup_chain_filtered` to avoid
/// choosing pre-setups the cascade would also run. (i4 gap 6.)
fn commands_triggered_by_cascade(domain: &Domain, cmd: &Command) -> BTreeSet<String> {
    let mut out = BTreeSet::new();
    let mut stack: Vec<String> = Vec::new();
    if let Some(ev) = &cmd.emits {
        for p in &domain.policies {
            if &p.on_event == ev { stack.push(p.trigger_command.clone()); }
        }
    }
    while let Some(name) = stack.pop() {
        if !out.insert(name.clone()) { continue; }
        if let Some((_, c)) = find_cmd_with_agg(domain, &name) {
            if let Some(ev) = &c.emits {
                for p in &domain.policies {
                    if &p.on_event == ev { stack.push(p.trigger_command.clone()); }
                }
            }
        }
    }
    out
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
                // Recurse: producer may itself have preconditions. We run
                // this ONCE even for MinSizeList (repeated Append calls
                // share the same prerequisite state — a second dispatch of
                // AddItem doesn't need another CreateCart).
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
                append_producer_for(&pre, producer, agg, &mut chain, &mut produced);
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

/// Append `producer` to `chain` the right number of times for `pre`:
///   * MinSizeList(_, n) — repeat the producer until the post-absorb
///     append count on its field reaches n. Existing entries in `chain`
///     (and their already-absorbed effects in `produced`) count toward n,
///     so an already-seeded chain doesn't double-seed.
///   * Everything else — add the producer once, deduped against an
///     already-present producer by name.
/// Updates `produced` for each added step so later preconditions see
/// the new state.
fn append_producer_for<'a>(
    pre: &Precondition,
    producer: &'a Command,
    agg: &'a Aggregate,
    chain: &mut Vec<&'a Command>,
    produced: &mut ProducedState,
) {
    if let Precondition::MinSizeList(field, n) = pre {
        let target = (*n).max(0) as usize;
        while produced.append_count(field) < target {
            chain.push(producer);
            produced.absorb(agg, producer);
        }
        return;
    }
    if !chain.iter().any(|c| c.name == producer.name) {
        chain.push(producer);
        produced.absorb(agg, producer);
    }
}

/// Same as `plan_setup_chain` but skips producer candidates that would
/// conflict with a cascade's own dispatch. A producer is skipped iff it's
/// in `exclude` (cascade-triggered) AND carries a lifecycle transition
/// on `agg`. The double condition is important:
///   * Cascade-triggered only → safe to pre-run when the command has
///     no lifecycle transition (e.g. AddToWaitlist in restaurant_
///     reservations: cascade-triggered via TableOccupied, but no
///     lifecycle transition, so pre-running doesn't advance state).
///   * Cascade-triggered AND lifecycle-transition → pre-running
///     advances state past the from_state the cascade expects, so
///     leave it to the cascade (e.g. DeployPages for MarkLive's
///     precondition in CloudflareDeploy).
/// When the only producer is excluded, the precondition is left unmet —
/// correct for cascade tests because the cascade runs the producer
/// itself during event propagation. (i4 gap 6.)
fn plan_setup_chain_filtered<'a>(
    domain: &'a Domain,
    agg: &'a Aggregate,
    target_cmd: &'a Command,
    depth: usize,
    visited: &mut Vec<&'a str>,
    exclude: &BTreeSet<String>,
) -> SetupPlan<'a> {
    if depth == 0 { return SetupPlan::Chain(Vec::new()); }
    if visited.contains(&target_cmd.name.as_str()) { return SetupPlan::Chain(Vec::new()); }
    visited.push(target_cmd.name.as_str());
    let mut chain: Vec<&Command> = Vec::new();
    let mut produced: ProducedState = ProducedState::default();
    let mut unsatisfiable = false;

    let is_cascade_triggered_transition = |p: &&Command| -> bool {
        if !exclude.contains(&p.name) { return false; }
        if let Some(lc) = &agg.lifecycle {
            return lc.transitions.iter().any(|t| t.command == p.name);
        }
        false
    };

    for pre in collect_preconditions(agg, target_cmd) {
        if produced.satisfies(&pre) { continue; }
        if precondition_default_holds(agg, &pre) { continue; }
        let producer = find_producer(domain, agg, &pre)
            .filter(|p| !is_cascade_triggered_transition(p));
        match producer {
            Some(producer) => {
                let sub_chain = match plan_setup_chain_filtered(domain, agg, producer, depth - 1, visited, exclude) {
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
                append_producer_for(&pre, producer, agg, &mut chain, &mut produced);
            }
            None => {
                // No non-excluded producer — the cascade itself will
                // satisfy this precondition, or there's genuinely no
                // producer. Either way, leave it unchained.
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
    /// Per-field count of Append mutations across chain steps. A count
    /// of 0 means no Append on that field; count ≥ 1 satisfies
    /// NonEmptyList, count ≥ N satisfies MinSizeList(_, N). Counts
    /// come from `absorb` — each chain step contributes one per Append
    /// mutation per field. (i4 gap 7.)
    append_counts: BTreeMap<String, usize>,
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
                    *self.append_counts.entry(m.field.clone()).or_insert(0) += 1;
                }
                MutationOp::Increment => {
                    self.incremented_fields.insert(m.field.clone());
                }
                MutationOp::Decrement | MutationOp::Toggle => {}
                // i106 — Multiply/Clamp/Decay touch the field but the
                // resulting numeric value depends on prior state we
                // don't track here. Treat as "incremented" for the
                // purposes of producer detection — same conservative
                // path Increment takes.
                MutationOp::Multiply | MutationOp::Decay => {
                    self.incremented_fields.insert(m.field.clone());
                }
                MutationOp::Clamp => {
                    self.incremented_fields.insert(m.field.clone());
                }
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

    fn append_count(&self, field: &str) -> usize {
        self.append_counts.get(field).copied().unwrap_or(0)
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
            Precondition::NonEmptyList(f) => self.append_count(f) >= 1,
            Precondition::MinSizeList(f, n) => self.append_count(f) >= (*n).max(0) as usize,
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
        // > / >= / NonEmptyList / MinSizeList never hold by default —
        // need a producer.
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
        Precondition::NonEmptyList(field) | Precondition::MinSizeList(field, _) => {
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
            // Append step satisfies them.
            "gt"  if n == 0 => Some(Precondition::NonEmptyList(field)),
            "gte" if n == 1 => Some(Precondition::NonEmptyList(field)),
            "any" => Some(Precondition::NonEmptyList(field)),
            // `size >= N` for N ≥ 2: carry N as the minimum size that
            // satisfies. `size > N` for N ≥ 1: carry N+1 (same min).
            // The chain planner runs the Append producer that many times.
            // (i4 gap 7.)
            "gte" if n >= 2 => Some(Precondition::MinSizeList(field, n)),
            "gt"  if n >= 1 => Some(Precondition::MinSizeList(field, n + 1)),
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

/// Find a command on `agg` whose direct effects satisfy `pre`. Direct
/// producers only — no cascade simulation. The cascade is locked down
/// separately via the `emits:` assertion in build_expect.
///
/// Strategy varies by precondition shape:
///   * Equals(f,v)  — Set mutation `to: v` on f, OR lifecycle transition
///     to v on f.
///   * GreaterThan(f,n) / GreaterOrEqual(f,n) — Set mutation landing f
///     at an integer ≥ n+1 (or n for >=), OR an Increment mutation on f.
///   * LessThan(f,n) — Set mutation landing f at an integer < n.
///   * NonEmptyList(f) — Append mutation on f.
///   * MinSizeList(f, _) — Append mutation on f (caller repeats it N times).
///   * EmptyList — never reached (default-satisfied earlier).
fn find_producer<'a>(
    _domain: &'a Domain,
    agg: &'a Aggregate,
    pre: &Precondition,
) -> Option<&'a Command> {
    match pre {
        Precondition::Equals(field, value) => find_equals_producer(agg, field, value),
        Precondition::GreaterThan(field, n) => find_int_producer(agg, field, *n + 1, true),
        Precondition::GreaterOrEqual(field, n) => find_int_producer(agg, field, *n, true),
        Precondition::LessThan(field, n) => find_int_producer(agg, field, *n - 1, false),
        Precondition::NonEmptyList(field) => find_append_producer(agg, field),
        Precondition::MinSizeList(field, _) => find_append_producer(agg, field),
        Precondition::EmptyList(_) => None,
    }
}

fn find_equals_producer<'a>(
    agg: &'a Aggregate,
    field: &str,
    value: &str,
) -> Option<&'a Command> {
    let by_mutation = agg.commands.iter().find(|c| {
        c.mutations.iter().any(|m| {
            matches!(m.operation, MutationOp::Set)
                && m.field == field
                && mutation_value_matches(&m.value, value)
        })
    });
    if by_mutation.is_some() { return by_mutation; }

    if let Some(lc) = &agg.lifecycle {
        if lc.field == field {
            return lc.transitions.iter()
                .filter(|t| t.to_state == value)
                .find_map(|t| agg.commands.iter().find(|c| c.name == t.command));
        }
    }

    None
}

/// Find a producer that lands `field` at an integer satisfying the
/// caller's bound. `at_least` chooses the direction: true means the
/// chosen value must be ≥ `target`, false means ≤ `target`.
fn find_int_producer<'a>(
    agg: &'a Aggregate,
    field: &str,
    target: i64,
    at_least: bool,
) -> Option<&'a Command> {
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
    // bounds where target is small (one increment lands at 1).
    if at_least && target <= 1 {
        let by_inc = agg.commands.iter().find(|c| {
            c.mutations.iter().any(|m| {
                matches!(m.operation, MutationOp::Increment) && m.field == field
            })
        });
        if by_inc.is_some() { return by_inc; }
    }

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

/// Expectations for the command under test. Sources, merged in order:
///   - Create-style commands: command attrs that match aggregate attrs,
///     plus the aggregate's lifecycle default (when no transition fires).
///   - Direct mutations on `cmd`: Set → field=value, Append → field_size=1,
///     Toggle → field=true. Direct producers only — no cascade simulation.
///   - Lifecycle transition for `cmd`: lc.field=to_state.
///   - Cascade lockdown: `emits: [E1, E2, ...]` from the static
///     emit→policy→trigger walk. Drift in policies surfaces as a test
///     failure — VCR for the cascade graph.
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
        // no transition (otherwise the transition below adds the to_state,
        // which is more specific).
        if let Some(lc) = &agg.lifecycle {
            let has_transition = lc.transitions.iter().any(|t| t.command == cmd.name);
            if !has_transition && !lc.default.is_empty() && seen.insert(lc.field.clone()) {
                out.push((lc.field.clone(), quote_string(&lc.default)));
            }
        }
    }

    // 2. Direct mutations on `cmd` (no cascade simulation — the cascade
    //    is locked down via `emits:` instead).
    for m in &cmd.mutations {
        match m.operation {
            MutationOp::Set => {
                let value = resolve_mutation_value(&m.value, cmd);
                out.retain(|(k, _)| k != &m.field);
                out.push((m.field.clone(), value));
                seen.insert(m.field.clone());
            }
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
            // Increment/Decrement depend on prior state — skip prediction.
            _ => {}
        }
    }

    // 3. Direct lifecycle transition for `cmd`.
    if let Some(lc) = &agg.lifecycle {
        if let Some(t) = lc.transitions.iter().find(|t| t.command == cmd.name) {
            out.retain(|(k, _)| k != &lc.field);
            out.push((lc.field.clone(), quote_string(&t.to_state)));
            seen.insert(lc.field.clone());
        }
    }

    // The cascade lockdown lives in a SEPARATE test (kind: :cascade) —
    // see emit_cascade_test below. Mixing it into the state assertion
    // causes overshoot: the state has cascaded past the command's
    // direct mutations, so per-field assertions fail. The split keeps
    // each test single-purpose.

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

/// Walk the static cascade from `cmd` and gather every aggregate type
/// that any triggered command lives on or references. Returns the
/// aggregates in cascade-traversal order (parents first), deduped.
/// Used by emit_cascade_test to ensure every aggregate the cascade
/// will hop through is bootstrapped before dispatch.
/// Collect every triggered command in the cascade, grouped by the
/// aggregate that owns it — but only for aggregates other than the
/// command's own.
///
/// Superseded by `commands_triggered_by_cascade` + `plan_setup_chain_filtered`
/// in the cascade-test builder. Kept for parity with the other conceiver
/// and possible future use. (i4 gap 6.)
#[allow(dead_code)]
fn cross_aggregate_triggered<'a>(
    domain: &'a Domain,
    cmd: &'a Command,
    cmd_agg: &'a Aggregate,
) -> Vec<(String, Vec<&'a Command>)> {
    let mut out: Vec<(String, Vec<&'a Command>)> = Vec::new();
    let mut visited_cmds: BTreeSet<String> = BTreeSet::new();

    fn walk<'b>(
        domain: &'b Domain,
        cmd_name: &str,
        own_agg: &str,
        out: &mut Vec<(String, Vec<&'b Command>)>,
        visited_cmds: &mut BTreeSet<String>,
    ) {
        if !visited_cmds.insert(cmd_name.to_string()) { return; }
        let Some((agg, c)) = find_cmd_with_agg(domain, cmd_name) else { return };
        if agg.name != own_agg {
            // Add this triggered cross-aggregate command, deduped per agg.
            let entry = out.iter_mut().find(|(a, _)| a == &agg.name);
            match entry {
                Some((_, cmds)) => {
                    if !cmds.iter().any(|x| x.name == c.name) { cmds.push(c); }
                }
                None => { out.push((agg.name.clone(), vec![c])); }
            }
        }
        if let Some(ev) = &c.emits {
            for p in &domain.policies {
                if &p.on_event == ev {
                    walk(domain, &p.trigger_command, own_agg, out, visited_cmds);
                }
            }
        }
    }

    visited_cmds.insert(cmd.name.clone());
    if let Some(ev) = &cmd.emits {
        for p in &domain.policies {
            if &p.on_event == ev {
                walk(domain, &p.trigger_command, &cmd_agg.name, &mut out, &mut visited_cmds);
            }
        }
    }
    out
}

fn aggregates_touched_by_cascade(
    domain: &Domain,
    cmd: &Command,
    cmd_agg: &Aggregate,
) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    let mut seen: BTreeSet<String> = BTreeSet::new();
    let mut visited_cmds: BTreeSet<String> = BTreeSet::new();

    fn walk(
        domain: &Domain,
        cmd_name: &str,
        out: &mut Vec<String>,
        seen: &mut BTreeSet<String>,
        visited_cmds: &mut BTreeSet<String>,
    ) {
        if !visited_cmds.insert(cmd_name.to_string()) { return; }
        let Some((agg, c)) = find_cmd_with_agg(domain, cmd_name) else { return };
        if seen.insert(agg.name.clone()) { out.push(agg.name.clone()); }
        for r in &c.references {
            if seen.insert(r.target.clone()) { out.push(r.target.clone()); }
        }
        if let Some(ev) = &c.emits {
            for p in &domain.policies {
                if &p.on_event == ev {
                    walk(domain, &p.trigger_command, out, seen, visited_cmds);
                }
            }
        }
    }

    seen.insert(cmd_agg.name.clone());
    out.push(cmd_agg.name.clone());
    for r in &cmd.references {
        if seen.insert(r.target.clone()) { out.push(r.target.clone()); }
    }
    if let Some(ev) = &cmd.emits {
        for p in &domain.policies {
            if &p.on_event == ev {
                walk(domain, &p.trigger_command, &mut out, &mut seen, &mut visited_cmds);
            }
        }
    }
    out
}

fn find_cmd_with_agg<'a>(domain: &'a Domain, cmd_name: &str) -> Option<(&'a Aggregate, &'a Command)> {
    for a in &domain.aggregates {
        if let Some(c) = a.commands.iter().find(|c| c.name == cmd_name) {
            return Some((a, c));
        }
    }
    None
}

fn to_snake_case(s: &str) -> String {
    crate::parser_helpers::to_snake_case(s)
}
