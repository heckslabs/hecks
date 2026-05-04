/// Parse the `(...)` arglist of a sentinel call into (name, default).
/// `name` is required and arrives as `:foo` or `"foo"` ; `default`
/// is optional and named (`default: "..."` form only ; positional
/// not supported).
fn parse_sentinel_args(s: &str, fname: &str) -> Option<(String, Option<String>)> {
    let after = &s[fname.len()..];
    let open = after.find('(')?;
    let close = after[open..].rfind(')')? + open;
    let inner = after[open + 1..close].trim();
    if inner.is_empty() { return None; }

    let parts = split_top_level_commas(inner);
    let mut iter = parts.into_iter();
    let name_raw = iter.next()?.trim().to_string();
    let name = name_raw
        .trim_start_matches(':')
        .trim_matches(|c: char| c == '"' || c == '\'')
        .to_string();
    if name.is_empty() { return None; }

    let mut default: Option<String> = None;
    for rest in iter {
        let r = rest.trim();
        if let Some(rest_after) = r.strip_prefix("default:") {
            let v = rest_after.trim();
            if v.starts_with('"') || v.starts_with('\'') {
                default = extract_string(v);
            } else if !v.is_empty() {
                default = Some(v.trim_end_matches(',').trim().to_string());
            }
        }
    }
    Some((name, default))
}

