/// Parse one `dispatch "Aggregate.Command", k1: v1, k2: v2` line into
/// a CadenceDispatch. Captures the qualified command name and an
/// ordered (key, source-text-value) attribute list. Returns None when
/// the line isn't a dispatch line.
pub fn parse_cadence_dispatch_line(line: &str) -> Option<CadenceDispatch> {
    let trimmed = line.trim();
    let command_name = extract_string(trimmed)?;
    let q1 = trimmed.find('"')?;
    let q2 = trimmed[q1 + 1..].find('"')? + q1 + 1;
    let after = trimmed[q2 + 1..].trim();
    let mut attrs: Vec<(String, String)> = Vec::new();
    if let Some(rest) = after.strip_prefix(',') {
        let kwargs = rest.trim();
        attrs = split_top_level_cadence(kwargs)
            .into_iter()
            .filter_map(|pair| {
                let p = pair.trim();
                let colon = p.find(':')?;
                let key = p[..colon].trim().trim_matches(':').to_string();
                let value = p[colon + 1..].trim().to_string();
                if key.is_empty() || value.is_empty() { None } else { Some((key, value)) }
            })
            .collect();
    }
    Some(CadenceDispatch { command_name, attrs })
}

