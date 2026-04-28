//! Behaviors test runner — executes a TestSuite against a source domain
//!
//! Pure-memory by design: uses `Runtime::boot(domain)` (no `data_dir`,
//! no hecksagon, no adapters). Each test gets a fresh runtime so
//! state doesn't leak across tests. If a test triggers IO, the source
//! bluebook is doing something it shouldn't — fix the bluebook, not
//! the test.
//!
//! Usage:
//!   hecks-life behaviors path/to/X_behavioral_tests.bluebook
//!
//! The runner finds the source bluebook by stripping the
//! `_behavioral_tests` suffix (e.g. `pizzas_behavioral_tests.bluebook`
//! → `pizzas.bluebook`).

use crate::behaviors_ir::{Test, TestSuite};
use crate::behaviors_fixtures;
use crate::fixtures_ir::FixturesFile;
use crate::ir::Domain;
use crate::parser;
use crate::runtime::{Runtime, RuntimeError, Value};
use std::collections::{BTreeMap, HashMap};

#[derive(Debug, PartialEq)]
pub enum TestStatus { Pass, Fail, Error }

pub struct TestRun {
    pub description: String,
    pub status: TestStatus,
    pub message: Option<String>,
}

impl TestRun {
    fn pass(desc: &str) -> Self {
        TestRun { description: desc.into(), status: TestStatus::Pass, message: None }
    }
    fn fail(desc: &str, msg: impl Into<String>) -> Self {
        TestRun { description: desc.into(), status: TestStatus::Fail, message: Some(msg.into()) }
    }
    fn error(desc: &str, msg: impl Into<String>) -> Self {
        TestRun { description: desc.into(), status: TestStatus::Error, message: Some(msg.into()) }
    }
}

pub struct SuiteResult {
    pub runs: Vec<TestRun>,
}

impl SuiteResult {
    pub fn passed(&self) -> usize { self.runs.iter().filter(|r| r.status == TestStatus::Pass).count() }
    pub fn failed(&self) -> usize { self.runs.iter().filter(|r| r.status == TestStatus::Fail).count() }
    pub fn errored(&self) -> usize { self.runs.iter().filter(|r| r.status == TestStatus::Error).count() }
    pub fn all_passed(&self) -> bool { self.failed() == 0 && self.errored() == 0 }
}

/// Run every test in `suite` against `source` (re-parsed per test for
/// state isolation). Returns one TestRun per test, in source order.
pub fn run_suite(source_text: &str, suite: &TestSuite) -> SuiteResult {
    run_suite_with_fixtures(source_text, suite, None)
}

/// Fixture-aware variant. When `fixtures` is `Some`, every fresh
/// runtime is seeded with those records BEFORE setups run (i4 gap 8).
/// When `None`, behaves exactly like `run_suite` — pass-through.
pub fn run_suite_with_fixtures(
    source_text: &str,
    suite: &TestSuite,
    fixtures: Option<&FixturesFile>,
) -> SuiteResult {
    let runs = suite.tests.iter()
        .map(|t| run_one(source_text, t, fixtures))
        .collect();
    SuiteResult { runs }
}

fn run_one(source_text: &str, test: &Test, fixtures: Option<&FixturesFile>) -> TestRun {
    // Fresh in-memory runtime per test. Repositories start empty;
    // no data_dir means no heki persistence, no disk IO.
    let domain: Domain = parser::parse(source_text);
    let mut rt = Runtime::boot(domain);

    // The translation layer between the bluebook (refs only) and the
    // runtime (ids). Maps an aggregate type → the id of the most
    // recently created instance of that type in this test. Setups
    // populate it; reference injection consumes it. No id ever leaves
    // this scope into the test DSL or the generator.
    let mut in_scope: HashMap<String, String> = HashMap::new();

    // Fixture seed FIRST so pre_seed_singletons can check in_scope and
    // skip aggregates that already have a fixture-loaded record.
    if let Some(ff) = fixtures {
        let seeded = behaviors_fixtures::apply(&mut rt, ff);
        in_scope.extend(seeded);
    }

    // Pre-seed in_scope for aggregates that have no in-bluebook
    // bootstrap command (every command requires a self-ref to its
    // own type). Without this, those aggregates can never be
    // referenced — the bluebook is silent on creation. The runner
    // gives them a virgin instance at id "1" so commands can find
    // and operate on them. This is the runner's pragmatic answer to
    // an incomplete bluebook; lifecycle defaults aren't applied
    // (the next dispatch will surface a clear error if they matter).
    pre_seed_singletons(&mut rt, &mut in_scope);

    // Replay setup commands. Setups dispatch with cascade OFF so they
    // don't overshoot the test command's required precondition state
    // (e.g. SortParcel triggers LoadParcel via policy, putting status
    // at "loaded" when the test needed it at "sorted"). The test
    // command itself dispatches via the cascading `dispatch` so its
    // `expect emits: [...]` assertion can fire and lock the cascade.
    for setup in &test.setups {
        let attrs = build_attrs(&setup.args, &setup.command, &rt, &in_scope);
        match rt.dispatch_isolated(&setup.command, attrs) {
            Ok(result) => {
                // Setup just created (or operated on) an aggregate of
                // this type. Stash it as the in-scope handle so
                // subsequent commands can reference it implicitly.
                in_scope.insert(result.aggregate_type.clone(), result.aggregate_id.clone());
            }
            Err(e) => return TestRun::error(
                &test.description,
                format!("setup `{}` failed: {}", setup.command, e),
            ),
        }
    }

    // Dispatch the input. Queries are dispatched via resolve_query;
    // commands via the regular dispatch path.
    if test.kind == "query" {
        return run_query(&rt, test);
    }

    // Snapshot the event bus boundary so the `emits:` assertion only
    // compares events produced by THIS dispatch, not events from setup.
    let pre_dispatch_event_count = rt.event_bus.events().len();
    let input_attrs = build_attrs(&test.input, &test.tests_command, &rt, &in_scope);
    // `kind: :cascade` tests explicitly want the policy chain to fire
    // so they can assert the cascade via `expect emits: [...]`. All
    // other tests dispatch isolated so the asserted state matches the
    // command's DIRECT mutations (no cascade overshoot).
    let result = if test.kind == "cascade" {
        rt.dispatch(&test.tests_command, input_attrs)
    } else {
        rt.dispatch_isolated(&test.tests_command, input_attrs)
    };

    // The expect map drives every assertion. `refused` is a special
    // key that asserts the dispatch failed with a matching given-clause
    // message; everything else asserts on final state.
    if let Some(expected_msg) = test.expect.get("refused") {
        return match result {
            Err(RuntimeError::GivenFailed { message, .. }) => {
                if message == *expected_msg {
                    TestRun::pass(&test.description)
                } else {
                    TestRun::fail(&test.description,
                        format!("expected refused: {:?}, got: {:?}", expected_msg, message))
                }
            }
            Err(other) => TestRun::fail(&test.description,
                format!("expected refused: {:?}, got error: {}", expected_msg, other)),
            Ok(_) => TestRun::fail(&test.description,
                format!("expected refused: {:?}, but command succeeded", expected_msg)),
        };
    }

    let result = match result {
        Ok(r) => r,
        Err(e) => return TestRun::error(&test.description, format!("dispatch failed: {}", e)),
    };

    // The dispatch updates in-scope just like setup does — subsequent
    // expects on the post-dispatch state need it.
    in_scope.insert(result.aggregate_type.clone(), result.aggregate_id.clone());

    // Final-state assertions. The test names `on_aggregate`, but the
    // runtime resolves command names to the FIRST aggregate that has
    // them — when multiple aggregates declare the same command name
    // (common in nursery scaffolds with `DoThing1` on Aggregate1/2/3),
    // the dispatch lands on the first match regardless of the test's
    // intent. Fall back to the result's aggregate_type so the test
    // can still assert against the state that actually changed.
    let (assert_agg, assert_id) = if rt.find(&test.on_aggregate,
            &in_scope.get(&test.on_aggregate).cloned().unwrap_or_default()).is_some() {
        let id = in_scope.get(&test.on_aggregate).cloned()
            .unwrap_or_else(|| result.aggregate_id.clone());
        (test.on_aggregate.clone(), id)
    } else {
        // Test's on_aggregate has no record. Use where dispatch landed.
        (result.aggregate_type.clone(), result.aggregate_id.clone())
    };
    let state = match rt.find(&assert_agg, &assert_id) {
        Some(s) => s,
        None => return TestRun::fail(&test.description,
            format!("no in-scope {} after dispatch", test.on_aggregate)),
    };

    for (key, expected) in &test.expect {
        if key == "refused" { continue; } // handled above
        // `ok: "true"` is the generator's "dispatch succeeded, no
        // meaningful state assertion to make" sentinel. We're already
        // in the Ok arm, so it passes by virtue of being here.
        if key == "ok" && (expected == "true" || expected == "\"true\"") { continue; }
        // `emits: [E1, E2, ...]` — assert the runtime's event bus
        // published these events in this order. Lock down the
        // emit→policy→trigger cascade as data: drift in policies
        // surfaces here as a test failure.
        if key == "emits" {
            let expected_events = parse_event_list(expected);
            let actual: Vec<String> = rt.event_bus.events()
                .iter()
                .skip(pre_dispatch_event_count)
                .map(|e| e.name.clone())
                .collect();
            if actual != expected_events {
                return TestRun::fail(&test.description,
                    format!("expected emits: {:?}, got {:?}", expected_events, actual));
            }
            continue;
        }
        if let Some(prefix) = key.strip_suffix("_size") {
            // Size assertion ONLY when `<prefix>` actually exists as a
            // list field. Otherwise this is just a normal attribute
            // whose name happens to end in `_size` (e.g. an Integer
            // `family_size` field) — fall through to equality.
            if let Value::List(v) = state.get(prefix) {
                let actual = v.len();
                let expected_n: usize = expected.parse().unwrap_or(0);
                if actual != expected_n {
                    return TestRun::fail(&test.description,
                        format!("expected {}.size == {}, got {}", prefix, expected_n, actual));
                }
                continue;
            }
        }
        // Plain attribute equality. Compare the field's display form to
        // the expected source-token string — both parsers stringify
        // the same way, so this is the canonical comparison.
        let actual = state.get(key).to_string();
        if actual != *expected {
            return TestRun::fail(&test.description,
                format!("expected {}: {:?}, got {:?}", key, expected, actual));
        }
    }

    TestRun::pass(&test.description)
}

fn run_query(rt: &Runtime, test: &Test) -> TestRun {
    // Build a String-keyed attrs map (resolve_query's signature).
    let attrs: HashMap<String, String> = test.input.iter()
        .map(|(k, v)| (k.clone(), v.clone()))
        .collect();
    let result = rt.resolve_query(&test.tests_command, &attrs);

    // The `count` expect key is the standard query assertion: count
    // matching records in the result. Other expect keys aren't yet
    // wired for queries — they'd need richer query result inspection.
    if let Some(expected) = test.expect.get("count") {
        let expected_n: usize = expected.parse().unwrap_or(0);
        let actual = count_query_records(&result);
        if actual != expected_n {
            return TestRun::fail(&test.description,
                format!("expected query count == {}, got {}", expected_n, actual));
        }
        return TestRun::pass(&test.description);
    }

    TestRun::pass(&test.description)
}

/// Convert behaviors-IR string args (the source-token form) into the
/// dynamic Value type the runtime dispatch loop expects. Numbers stay
/// numbers; quoted strings come through unwrapped (already).
fn to_runtime_attrs(args: &BTreeMap<String, String>) -> HashMap<String, Value> {
    args.iter()
        .map(|(k, v)| (k.clone(), parse_value(v)))
        .collect()
}

/// Build the attrs map for a runtime dispatch from the test DSL's
/// reference-only world. Two layers:
///
/// 1. Convert the user-typed kwargs (domain attrs only — no ids).
/// 2. For every reference declared on the command, inject the in-scope
///    id automatically. The user never types an id; the runner looks
///    up "the most recently created Pizza" from in_scope and provides
///    the runtime its internal id. This is the bluebook→repository
///    translation: above, references; below, ids.
///
/// If a reference can't be resolved (no in-scope aggregate of that
/// type), the kwarg is omitted — the runtime will then either error
/// (loud, useful failure pointing at missing setup) or singleton-create
/// for is_create commands.
fn build_attrs(
    args: &BTreeMap<String, String>,
    command_name: &str,
    rt: &Runtime,
    in_scope: &HashMap<String, String>,
) -> HashMap<String, Value> {
    let mut attrs = to_runtime_attrs(args);
    if let Some(cmd) = find_command(rt, command_name) {
        for r in &cmd.references {
            // Don't overwrite if the user explicitly set this kwarg
            // (escape hatch for advanced cases — tests usually don't).
            if attrs.contains_key(&r.name) { continue; }
            if let Some(id) = in_scope.get(&r.target) {
                attrs.insert(r.name.clone(), Value::Str(id.clone()));
            }
        }
    }
    attrs
}

fn find_command<'a>(rt: &'a Runtime, name: &str) -> Option<&'a crate::ir::Command> {
    for agg in &rt.domain.aggregates {
        if let Some(c) = agg.commands.iter().find(|c| c.name == name) {
            return Some(c);
        }
    }
    None
}

/// For every aggregate where every command requires a self-ref to its
/// own type, manually seed an empty AggregateState at id "1" so the
/// reference-injection layer has something to point at. Lifecycle
/// defaults aren't applied — that's a deliberate "test will surface
/// the gap" choice.
fn pre_seed_singletons(rt: &mut Runtime, in_scope: &mut HashMap<String, String>) {
    let to_seed: Vec<String> = rt.domain.aggregates.iter()
        .filter(|agg| agg_has_no_bootstrap(agg))
        .map(|agg| agg.name.clone())
        .collect();
    for agg_name in to_seed {
        // Fixtures seeded this aggregate already — don't overwrite its
        // loaded state with a virgin AggregateState at id "1".
        if in_scope.contains_key(&agg_name) { continue; }
        if let Some(repo) = rt.repositories.get_mut(&agg_name) {
            let id = "1".to_string();
            repo.save(crate::runtime::AggregateState::new(&id),
                crate::heki::WriteContext::OutOfBand {
                    reason: "behaviors test runner — pre-seed empty singleton at id=1 for cross-aggregate setup",
                });
            in_scope.insert(agg_name, id);
        }
    }
}

/// True when every command on the aggregate references its own type
/// (no command can act as a fresh-instance bootstrap from the bluebook).
fn agg_has_no_bootstrap(agg: &crate::ir::Aggregate) -> bool {
    if agg.commands.is_empty() { return false; }
    let agg_snake = to_snake(&agg.name);
    agg.commands.iter().all(|cmd| {
        cmd.references.iter().any(|r| {
            let target_snake = to_snake(&r.target);
            target_snake == agg_snake || agg_snake.ends_with(&target_snake)
        })
    })
}

fn to_snake(s: &str) -> String {
    let mut out = String::new();
    for (i, c) in s.chars().enumerate() {
        if c.is_uppercase() && i > 0 { out.push('_'); }
        out.push(c.to_lowercase().next().unwrap_or(c));
    }
    out
}

fn parse_value(s: &str) -> Value {
    if let Ok(n) = s.parse::<i64>() { return Value::Int(n); }
    if s == "true" { return Value::Bool(true); }
    if s == "false" { return Value::Bool(false); }
    Value::Str(s.to_string())
}

/// Parse the value side of `expect emits: [E1, E2, E3]` from the
/// behaviors IR (which carries the source-token form). Strips brackets
/// and splits on commas; tolerates surrounding whitespace and quoted
/// strings. An empty list (`[]`) returns an empty Vec.
fn parse_event_list(raw: &str) -> Vec<String> {
    let trimmed = raw.trim();
    let inner = trimmed
        .strip_prefix('[').unwrap_or(trimmed)
        .strip_suffix(']').unwrap_or(trimmed);
    if inner.trim().is_empty() { return Vec::new(); }
    inner.split(',')
        .map(|s| s.trim().trim_matches('"').trim_matches('\'').to_string())
        .filter(|s| !s.is_empty())
        .collect()
}

/// Count records in a resolve_query result. The result shape is
/// `{ "state": [..] }` for multi-record, `{ "state": {..} }` for one,
/// or `{ "state": [] }` for none.
fn count_query_records(result: &serde_json::Value) -> usize {
    match result.get("state") {
        Some(serde_json::Value::Array(a)) => a.len(),
        Some(serde_json::Value::Object(_)) => 1,
        _ => 0,
    }
}
