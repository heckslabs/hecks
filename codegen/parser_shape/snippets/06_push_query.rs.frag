fn push_query(line: &str, agg: &mut Aggregate, depth: &mut usize) {
    let name = extract_string(line).unwrap_or_else(|| {
        line.split_whitespace().nth(1).unwrap_or("").trim_matches('"').to_string()
    });
    let desc = extract_second_string(line);
    agg.queries.push(Query { name, description: desc });
    if ends_with_do_block(line) { *depth += 1; }
}

