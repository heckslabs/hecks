pub fn parse_fixture(line: &str) -> Fixture {
    let aggregate_name = extract_string(line).unwrap_or_default();
    let mut attributes = vec![];

    // Parse key: <value> pairs after the aggregate name. Values may be
    // strings (with commas inside), arrays, hashes, or numbers — so we
    // split on commas only at the top level (outside "...", [...], {...}).
    //   fixture "Vow", name: "Hi, world", words: "Be transparent."
    if let Some(comma_pos) = line.find(',') {
        let rest = &line[comma_pos + 1..];
        for part in split_top_level_commas(rest) {
            let part = part.trim();
            if let Some(colon) = part.find(':') {
                let key = part[..colon].trim().to_string();
                let raw = part[colon + 1..].trim();
                // For string-literal values, unwrap the quotes; otherwise
                // keep the raw source token (numbers, arrays, hashes, bare).
                let val = if raw.starts_with('"') {
                    extract_string(raw).unwrap_or_else(|| raw.to_string())
                } else {
                    raw.to_string()
                };
                attributes.push((key, val));
            }
        }
    }

    Fixture { name: None, aggregate_name, attributes }
}

