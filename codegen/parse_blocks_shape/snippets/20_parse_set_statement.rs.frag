/// Parse one (possibly glued-multi-line) `set :attr, value_spec` line
/// into an `(attr, ValueSpec)` pair. Three forms recognized for the
/// value : same as the with-spec evaluator (literal / from_event /
/// from_pm). Returns None when the shape is unparseable.
///
///   set :steering_target, from_event(:target)
///   set :carrying, "body"
///   set :tick, from_pm(:tick, default: "0")
fn parse_set_statement(line: &str) -> Option<(String, ValueSpec)> {
    let trimmed = line.trim();
    if !is_set_start(trimmed) { return None; }
    // Drop the leading `set` keyword + whitespace.
    let rest = trimmed[3..].trim_start();
    // Find the first comma at top-level (parens not respected — there
    // shouldn't be any in the attr name).
    let comma = rest.find(',')?;
    let attr_raw = rest[..comma].trim();
    let attr = attr_raw
        .trim_matches(|c| c == '"' || c == '\'' || c == ':')
        .to_string();
    if attr.is_empty() { return None; }
    let val_raw = rest[comma + 1..].trim();
    let spec = parse_value_spec(val_raw)?;
    Some((attr, spec))
}

