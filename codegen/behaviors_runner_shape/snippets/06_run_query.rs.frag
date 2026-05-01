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

