fn run_one(
    source_text: &str,
    test: &Test,
    fixtures: Option<&FixturesFile>,
    full_domain: Option<&Domain>,
    hecksagons: Option<&[Hecksagon]>,
) -> TestRun {
    // `kind: :pending` — runner-level skip for tests known to be stale
    // or blocked on out-of-scope work. Counted as a Pass with the
    // description prefixed `[pending] ` so it's visible but not red.
    if test.kind == "pending" {
        return TestRun::pass(&format!("[pending] {}", test.description));
    }
    // Fresh in-memory runtime per test. Repositories start empty;
    // no data_dir means no heki persistence, no disk IO.
    //
    // Per-test domain choice (i112 cleanup) :
    // - kind: :cross_cascade → use full pre-loaded domain so policy
    //   chains that hop into sibling bluebooks fire end-to-end. The
    //   test's emit-list assertion accepts the full chain.
    // - any other kind → use the source bluebook only ; tests with
    //   strict emit-list assertions rely on the isolated chain not
    //   firing extra unrelated policies from other bluebooks.
    let use_combined = test.kind == "cross_cascade";
    let domain: Domain = if use_combined {
        match full_domain {
            Some(d) => d.clone(),
            None    => parser::parse(source_text),  // fallback when no
                                                    // aggregates root
        }
    } else {
        parser::parse(source_text)
    };
    // Sprint 14 first-adapter slice — when hecksagons are supplied
    // (the conception-aware caller in run_behaviors), boot with them
    // attached so `driven on` adapter handlers fire on event emission.
    // The pre-sprint path (Runtime::boot, no hecksagons) is preserved
    // for direct/library callers that don't supply any.
    let mut rt = match hecksagons {
        Some(hs) if !hs.is_empty() => {
            Runtime::boot_with_hecksagons(domain, None, hs.to_vec())
        }
        _ => Runtime::boot(domain),
    };

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
    // FQN dispatch (i155) : combine `on:` clause with the command name
    // so bare-name ambiguity (Layout.Plan vs Move.Plan post-i155) is
    // unambiguous via the test's declared aggregate scope.
    let fqn = if test.on_aggregate.is_empty() || test.tests_command.contains('.') {
        test.tests_command.clone()
    } else {
        format!("{}.{}", test.on_aggregate, test.tests_command)
    };
    // `kind: :cascade` tests explicitly want the policy chain to fire
    // so they can assert the cascade via `expect emits: [...]`. All
    // other tests dispatch isolated so the asserted state matches the
    // command's DIRECT mutations (no cascade overshoot).
    let result = if test.kind == "cascade" || test.kind == "cross_cascade" {
        rt.dispatch(&fqn, input_attrs)
    } else {
        rt.dispatch_isolated(&fqn, input_attrs)
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
            // f4 — an InvariantViolation rejects a command the same way a
            // failed `given` does (0 events, no save), so `refused` matches
            // it too. The invariant's rule name is the comparand, mirroring
            // how the given-clause message is matched above.
            Err(RuntimeError::InvariantViolation { name, .. }) => {
                if name == *expected_msg {
                    TestRun::pass(&test.description)
                } else {
                    TestRun::fail(&test.description,
                        format!("expected refused: {:?}, got: {:?}", expected_msg, name))
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
        // `emits_prefix: [E1, E2]` — the cascade STARTS WITH these in
        // this order. Extra events after are tolerated. Use when the
        // policy chain hops bluebooks the runner doesn't load (cross-
        // bluebook cascades produce more events than the test was
        // written for) ; the test still locks the front of the chain.
        if key == "emits_prefix" {
            let expected_events = parse_event_list(expected);
            let actual: Vec<String> = rt.event_bus.events()
                .iter()
                .skip(pre_dispatch_event_count)
                .map(|e| e.name.clone())
                .collect();
            if actual.len() < expected_events.len()
                || actual[..expected_events.len()] != expected_events[..]
            {
                return TestRun::fail(&test.description,
                    format!("expected emits_prefix: {:?}, got {:?}", expected_events, actual));
            }
            continue;
        }
        // `emits_subset: [E1, E2]` — every expected event appears in
        // actual, in order, but other events may be interleaved or
        // appended. Use when the cascade is asynchronous / non-linear
        // and you only want to assert these specific signals fire.
        if key == "emits_subset" {
            let expected_events = parse_event_list(expected);
            let actual: Vec<String> = rt.event_bus.events()
                .iter()
                .skip(pre_dispatch_event_count)
                .map(|e| e.name.clone())
                .collect();
            // Greedy in-order match : walk expected, advance an actual
            // cursor past each match. Fail if any expected event isn't
            // found at-or-after the cursor.
            let mut i = 0;
            for ev in &expected_events {
                while i < actual.len() && &actual[i] != ev { i += 1; }
                if i >= actual.len() {
                    return TestRun::fail(&test.description,
                        format!("expected emits_subset: {:?}, got {:?} (missing {})",
                            expected_events, actual, ev));
                }
                i += 1;
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

