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
    // this as a suite-level comment so `storehouse conceive-behaviors`
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
    //
    // Planner switch (final-gate step 2b): driven by the kernel interpreter's
    // plan_commands, not generator's plan_setup_chain. Same recursion and depth
    // cap; the kernel returns the chain as &Command refs directly.
    let chain = match crate::conception_kernel::planner::plan_commands(agg, cmd) {
        crate::conception_kernel::planner::PlanCommands::Chain(chain) => chain,
        crate::conception_kernel::planner::PlanCommands::Unsatisfiable => return None,
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
            // Planner switch (step 2b): bootstrap-create prepend driven by the
            // kernel interpreter's plan_commands.
            let create_chain = match crate::conception_kernel::planner::plan_commands(agg, create) {
                crate::conception_kernel::planner::PlanCommands::Chain(c) => c,
                crate::conception_kernel::planner::PlanCommands::Unsatisfiable => return None,
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
                // Planner switch (step 2b): cross-ref create prepend driven by
                // the kernel interpreter's plan_commands, in the TARGET agg's
                // context (the chain is same-aggregate within target_agg).
                let create_chain = match crate::conception_kernel::planner::plan_commands(target_agg, create) {
                    crate::conception_kernel::planner::PlanCommands::Chain(c) => c,
                    crate::conception_kernel::planner::PlanCommands::Unsatisfiable => return None,
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
    // Planner switch (step 2b): the cascade test's prerequisite chain is driven
    // by the kernel interpreter's plan_commands, same as the state test.
    let chain = match crate::conception_kernel::planner::plan_commands(agg, cmd) {
        crate::conception_kernel::planner::PlanCommands::Chain(chain) => chain,
        crate::conception_kernel::planner::PlanCommands::Unsatisfiable => return None,
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
            // Planner switch (step 2b): cascade-test bootstrap prepend driven by
            // the kernel interpreter's plan_commands.
            let create_chain = match crate::conception_kernel::planner::plan_commands(agg, create) {
                crate::conception_kernel::planner::PlanCommands::Chain(c) => c,
                crate::conception_kernel::planner::PlanCommands::Unsatisfiable => return None,
            };
            // Create command first, then its dependency chain, then the
            // existing setups. The kernel returns the create's prerequisites;
            // the chain of a Create command is empty in practice, so the order
            // here only matters for completeness.
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
    // the kernel's `plan_commands_filtered` skips producers that would pre-advance
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
            // Planner switch (slice 3b): the cascade-aware filtered chain is
            // driven by the kernel interpreter's plan_commands_filtered. The
            // cascade-triggered set (triggered_in_cascade) is the caller's
            // precomputed input; the kernel applies the producer-exclusion.
            let chain = match crate::conception_kernel::planner::plan_commands_filtered(target_agg, triggered, &triggered_in_cascade) {
                crate::conception_kernel::planner::PlanCommands::Chain(c) => c,
                crate::conception_kernel::planner::PlanCommands::Unsatisfiable => continue,
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

/// Delegates to the kernel's query starter-test renderer (conception_kernel::query).
fn query_test(agg: &Aggregate, q: &Query) -> String {
    crate::conception_kernel::query::query_test(agg, q)
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

/// Detect givens the conceiver cannot parse into a known Precondition.
/// Returns (aggregate, command, expression) for each. An unparseable given is
/// intent the conceiver cannot honor — the caller FAILS LOUDLY rather than
/// silently dropping the command (which would yield a stale, lying suite). The
/// bluebook is the intent. (2026-06-13.)
pub fn detect_unparseable_givens(domain: &Domain) -> Vec<(String, String, String)> {
    let mut out: Vec<(String, String, String)> = Vec::new();
    for agg in &domain.aggregates {
        for cmd in &agg.commands {
            for g in &cmd.givens {
                if parse_precondition(&g.expression).is_none() {
                    out.push((agg.name.clone(), cmd.name.clone(), g.expression.clone()));
                }
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
/// Delegates to the kernel's self-reference detector (conception_kernel::bootstrap).
fn self_ref_for(agg: &Aggregate, cmd: &Command) -> Option<String> {
    crate::conception_kernel::bootstrap::self_ref_for(agg, cmd)
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
/// Delegates to the kernel's bootstrap-command selector (conception_kernel::bootstrap).
fn pick_create_command(agg: &Aggregate) -> Option<&Command> {
    crate::conception_kernel::bootstrap::pick_create_command(agg)
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
/// `pick_safe_bootstrap` and the kernel's `plan_commands_filtered` to avoid
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
                MutationOp::Decrement | MutationOp::Toggle | MutationOp::Delete | MutationOp::Remove => {}
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
            // `size < N` (N>=1) is satisfied by the EMPTY list a fresh create
            // yields (size 0 < N) — default-held, no setup step. Without this,
            // a command guarded by `toppings.size < 10` had an unparseable
            // given and was silently dropped from the suite. (2026-06-13.)
            "lt" if n >= 1 => Some(Precondition::EmptyList(field)),
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

/// Emit a single setup line for a command on `agg`. Reference kwargs
/// are NOT emitted — the runner injects them from its in-scope map
/// at dispatch time. Bluebook layer stays id-free.
/// Delegates to the kernel's per-command renderer (conception_kernel::emit).
fn emit_setup(_agg: &Aggregate, cmd: &Command) -> String {
    crate::conception_kernel::emit::setup_line(cmd)
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
    crate::conception_kernel::emit::input_pairs(cmd)
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
/// Delegates to the kernel's expected-state builder (conception_kernel::expect).
fn build_expect(
    domain: &Domain,
    agg: &Aggregate,
    cmd: &Command,
    lifecycle_to: Option<(String, String)>,
) -> Vec<(String, String)> {
    crate::conception_kernel::expect::build_expect(domain, agg, cmd, lifecycle_to)
}

// ─── format helpers ──────────────────────────────────────────────────

fn join_kvs(pairs: &[(String, String)]) -> String {
    crate::conception_kernel::emit::join_kvs(pairs)
}

/// Delegates to the kernel's test namer (conception_kernel::emit).
fn test_name(cmd: &Command, agg: &Aggregate) -> String {
    crate::conception_kernel::emit::test_name(cmd, agg)
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
/// Superseded by `commands_triggered_by_cascade` + the kernel's `plan_commands_filtered`
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
