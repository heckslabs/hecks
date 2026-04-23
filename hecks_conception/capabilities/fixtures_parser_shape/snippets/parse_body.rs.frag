    let mut file = FixturesFile {
        domain_name: String::new(),
        fixtures: vec![],
        catalogs: std::collections::BTreeMap::new(),
    };
    let lines: Vec<&str> = source.lines().collect();
    let mut i = 0;
    let mut current_agg: Option<String> = None;
    let mut depth: usize = 0;

    while i < lines.len() {
        let line = lines[i].trim();
        if line.starts_with('#') || line.is_empty() { i += 1; continue; }

        if line.starts_with("Hecks.fixtures") {
            if let Some(name) = extract_string(line) { file.domain_name = name; }
            depth += 1;
        } else if line.starts_with("aggregate ") && ends_with_do_block(line) {
            current_agg = extract_string(line);
            if let Some(agg) = current_agg.clone() {
                if let Some(schema) = extract_schema_kwarg(line) {
                    file.catalogs.insert(agg, schema);
                }
            }
            depth += 1;
        } else if line.starts_with("fixture ") {
            if let Some(agg) = &current_agg {
                file.fixtures.push(parse_fixture_line(line, agg));
            }
        } else if line == "end" {
            if depth > 0 { depth -= 1; }
            // Closing the `aggregate` block clears the current aggregate.
            // Closing the outer `Hecks.fixtures` leaves depth at 0.
            if depth == 1 { current_agg = None; }
        }
        i += 1;
    }

    file
