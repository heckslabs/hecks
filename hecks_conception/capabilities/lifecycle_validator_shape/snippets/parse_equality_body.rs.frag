    let parts: Vec<&str> = expr.splitn(2, "==").collect();
    if parts.len() != 2 { return None; }
    let field = parts[0].trim().to_string();
    if field.is_empty() || !field.chars().all(|c| c.is_alphanumeric() || c == '_') {
        return None;
    }
    let raw = parts[1].trim().trim_end_matches('}').trim();
    if !raw.starts_with('"') { return None; }
    let end = raw[1..].find('"')? + 1;
    Some((field, raw[1..end].to_string()))
