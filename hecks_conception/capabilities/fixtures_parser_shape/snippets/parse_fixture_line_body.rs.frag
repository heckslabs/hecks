    let label = extract_string(line);
    let mut attributes: Vec<(String, String)> = vec![];

    if let Some(comma_pos) = line.find(',') {
        let rest = &line[comma_pos + 1..];
        for part in split_top_level_commas(rest) {
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

    Fixture {
        name: label,
        aggregate_name: aggregate_name.to_string(),
        attributes,
    }
