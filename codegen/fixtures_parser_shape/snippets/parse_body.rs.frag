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
        } else if line.starts_with("fixture ") && ends_with_do_block(line) {
            // Dispatch-fixture block form (no enclosing `aggregate`):
            //   fixture "label" do
            //     dispatch "Domain::Agg.Command", k: v
            //   end
            // The `fixture` line's string is the label; the inner
            // `dispatch` line carries the command FQN (whose bare
            // aggregate segment becomes aggregate_name) and the seed
            // kwargs. Consume the block to its matching `end` so the
            // inner lines aren't reparsed as top-level statements. The
            // command verb itself is intentionally not preserved — the
            // seed IR shape is (aggregate, name, attributes).
            let label = extract_string(line);
            let mut aggregate_name = String::new();
            let mut attributes: Vec<(String, String)> = vec![];
            i += 1;
            while i < lines.len() {
                let inner = lines[i].trim();
                if inner == "end" { break; }
                if inner.starts_with("dispatch ") {
                    // FQN = "Domain::Agg.Command" — aggregate is the
                    // segment after the last "::" and before the ".".
                    if let Some(fqn) = extract_string(inner) {
                        let before_dot = fqn.split('.').next().unwrap_or("");
                        aggregate_name = before_dot
                            .rsplit("::").next().unwrap_or(before_dot).to_string();
                    }
                    // kwargs follow the first comma after the FQN string
                    // (the FQN never contains a top-level comma).
                    if let Some(comma_pos) = inner.find(',') {
                        for part in split_top_level_commas(&inner[comma_pos + 1..]) {
                            let part = part.trim();
                            if let Some(colon) = part.find(':') {
                                let key = part[..colon].trim().to_string();
                                let raw = part[colon + 1..].trim();
                                let val = if raw.starts_with('"') {
                                    extract_string_escape_aware(raw)
                                        .map(|s| expand_ruby_escapes(&s))
                                        .unwrap_or_else(|| raw.to_string())
                                } else {
                                    raw.to_string()
                                };
                                attributes.push((key, val));
                            }
                        }
                    }
                }
                i += 1;
            }
            file.fixtures.push(Fixture { name: label, aggregate_name, attributes });
        } else if line.starts_with("fixture ") {
            // Multi-line fixture support: if the line ends with a
            // trailing comma (continuation marker), greedily consume
            // subsequent non-keyword, non-empty lines into a single
            // logical fixture line. Blank / comment lines are skipped
            // across; `fixture`, `aggregate`, `end`, and `Hecks.fixtures`
            // terminate the span. See inbox i57.
            let mut combined = line.to_string();
            while combined.trim_end().ends_with(',') && i + 1 < lines.len() {
                let next = lines[i + 1].trim();
                if next.is_empty() || next.starts_with('#') {
                    i += 1;
                    continue;
                }
                if next.starts_with("fixture ")
                    || next.starts_with("aggregate ")
                    || next.starts_with("end")
                    || next.starts_with("Hecks.fixtures")
                {
                    break;
                }
                combined.push(' ');
                combined.push_str(next);
                i += 1;
            }
            if let Some(agg) = &current_agg {
                file.fixtures.push(parse_fixture_line(&combined, agg));
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
