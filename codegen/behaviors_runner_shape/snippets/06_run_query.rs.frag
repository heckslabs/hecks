fn run_query(rt: &Runtime, test: &Test) -> TestRun {
    // Build a String-keyed attrs map (resolve_query's signature).
    let attrs: HashMap<String, String> = test.input.iter()
        .map(|(k, v)| (k.clone(), v.clone()))
        .collect();
    // Qualify by the test's `on:` aggregate so a query name shared across
    // aggregates (e.g. both Sprint and Story declare `Board`) resolves to the
    // one under test — mirrors the command side's on_aggregate routing and
    // avoids the name-only first-match pick (the dream_content_smoke flake).
    let result = rt.resolve_query_qualified(None, &test.on_aggregate, &test.tests_command, &attrs);

    // `count` asserts how many records the query returned.
    if let Some(expected) = test.expect.get("count") {
        let expected_n: usize = expected.parse().unwrap_or(0);
        let actual = count_query_records(&result);
        if actual != expected_n {
            return TestRun::fail(&test.description,
                format!("expected query count == {}, got {}", expected_n, actual));
        }
        return TestRun::pass(&test.description);
    }

    // The records in query order — resolve_query has already applied the
    // declared where / order_by / limit, so position here IS sort order.
    let records = query_records(&result);

    // `includes: { k: v, .. }` — at least one record matches every field.
    // Membership, order-independent. Fields match the record's stored
    // attribute names (the identity attribute included, under its own
    // name — e.g. `ref` or `repo_key`), mirroring command-side equality.
    if let Some(spec) = test.expect.get("includes") {
        let pairs = parse_field_map(spec);
        if records.iter().any(|r| record_matches(r, &pairs)) {
            return TestRun::pass(&test.description);
        }
        return TestRun::fail(&test.description,
            format!("expected a record including {}, got {} record(s): {:?}",
                spec, records.len(), records));
    }

    // `first: { k: v, .. }` — the FIRST record (post order_by) matches every
    // field. Pins the head of a sorted query : declare out of order, assert
    // the smallest sorts to the front.
    if let Some(spec) = test.expect.get("first") {
        let pairs = parse_field_map(spec);
        return match records.first() {
            Some(r) if record_matches(r, &pairs) =>
                TestRun::pass(&test.description),
            Some(r) => TestRun::fail(&test.description,
                format!("expected first record {}, got {}", spec, r)),
            None => TestRun::fail(&test.description,
                format!("expected first record {}, got no records", spec)),
        };
    }

    TestRun::pass(&test.description)
}

/// The query result's records as a flat Vec, in result order. resolve_query
/// returns `{ "state": [..] }` for multi-record, `{ "state": {..} }` for a
/// lone record, or no/empty state for none.
fn query_records(result: &serde_json::Value) -> Vec<serde_json::Value> {
    match result.get("state") {
        Some(serde_json::Value::Array(a)) => a.clone(),
        Some(serde_json::Value::Object(o)) =>
            vec![serde_json::Value::Object(o.clone())],
        _ => Vec::new(),
    }
}

/// Parse a behaviors brace-map token — `{ k: "v", k2: "v2" }` — into ordered
/// (key, value) pairs. The behaviors parser stores the brace expression
/// verbatim (inner quotes intact), so strip surrounding braces, split on
/// commas, then split each pair on its first colon and trim quotes.
fn parse_field_map(spec: &str) -> Vec<(String, String)> {
    let inner = spec.trim()
        .trim_start_matches('{')
        .trim_end_matches('}')
        .trim();
    if inner.is_empty() {
        return Vec::new();
    }
    inner.split(',')
        .filter_map(|pair| {
            let (k, v) = pair.split_once(':')?;
            let k = k.trim().trim_matches('"').trim_matches('\'').to_string();
            let v = v.trim().trim_matches('"').trim_matches('\'').to_string();
            Some((k, v))
        })
        .collect()
}

/// True when a query record matches every (field, value) pair. A JSON string
/// field compares to the raw value ; numbers / bools compare via their
/// display form. A missing field never matches.
fn record_matches(record: &serde_json::Value, pairs: &[(String, String)]) -> bool {
    pairs.iter().all(|(k, v)| match record.get(k) {
        Some(serde_json::Value::String(s)) => s == v,
        Some(other) => other.to_string() == *v,
        None => false,
    })
}
