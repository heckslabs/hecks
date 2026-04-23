// Snippet: split_kwarg body. Splits `key: value` into a (key, value)
// pair; strings are unwrapped, other tokens kept as source bytes.
    let colon = part.find(':')?;
    let key = part[..colon].trim().to_string();
    if key.is_empty()
        || !key.chars().next().map_or(false, |c| c.is_ascii_lowercase())
        || !key.chars().all(|c| c.is_alphanumeric() || c == '_')
    {
        return None;
    }
    let raw = part[colon + 1..].trim().trim_end_matches(',').trim();
    let val = if raw.starts_with('"') {
        extract_string(raw).unwrap_or_else(|| raw.to_string())
    } else {
        raw.to_string()
    };
    Some((key, val))
