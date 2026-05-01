//! Hecksagon parser helpers — tiny pure functions pulled out of the
//! main parser so each file stays under the 200-line code budget.

/// The first quoted string in a line (`"foo"` → `foo`).
pub fn between_quotes(s: &str) -> Option<String> {
    let start = s.find('"')?;
    let tail = &s[start + 1..];
    let end = tail.find('"')?;
    Some(tail[..end].to_string())
}

/// Drop surrounding double quotes if both present.
pub fn strip_quotes(s: &str) -> String {
    let t = s.trim();
    if t.starts_with('"') && t.ends_with('"') && t.len() >= 2 { t[1..t.len() - 1].to_string() }
    else { t.to_string() }
}

/// Drop leading `:` and trailing commas from a `:symbol` token.
pub fn strip_symbol(s: &str) -> String {
    s.trim().trim_start_matches(':').trim_end_matches(',').trim().to_string()
}

/// Return (first_symbol, rest). Handles `:shell, name: :foo, ...`.
pub fn split_first_symbol(s: &str) -> (String, &str) {
    let t = s.trim_start();
    if !t.starts_with(':') { return (String::new(), t); }
    let rest = &t[1..];
    let end = rest.find(|c: char| c == ',' || c.is_whitespace())
        .unwrap_or(rest.len());
    let kind = rest[..end].trim().to_string();
    let after = rest[end..].trim_start_matches(|c: char| c.is_whitespace() || c == ',');
    (kind, after)
}

/// `a, b, c` → `[a, b, c]` — commas inside brackets/parens/quotes do
/// not split.
pub fn split_top_level_commas(s: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut depth = 0i32;
    let mut in_str = false;
    let mut current = String::new();
    let mut prev = '\0';
    for c in s.chars() {
        match c {
            '"' if prev != '\\' => { in_str = !in_str; current.push(c); }
            '[' | '{' | '(' if !in_str => { depth += 1; current.push(c); }
            ']' | '}' | ')' if !in_str => { depth -= 1; current.push(c); }
            ',' if !in_str && depth == 0 => {
                out.push(std::mem::take(&mut current));
            }
            _ => current.push(c),
        }
        prev = c;
    }
    if !current.trim().is_empty() { out.push(current); }
    out
}

/// First `:` that separates a key from a value at the top level —
/// skipping `:symbol` tokens where the colon starts an identifier.
pub fn find_top_level_colon(s: &str) -> Option<usize> {
    let chars: Vec<char> = s.chars().collect();
    let mut depth = 0i32;
    let mut in_str = false;
    let mut i = 0;
    while i < chars.len() {
        let c = chars[i];
        match c {
            '"' => in_str = !in_str,
            '[' | '{' | '(' if !in_str => depth += 1,
            ']' | '}' | ')' if !in_str => depth -= 1,
            ':' if !in_str && depth == 0 => {
                let prev = if i == 0 { ' ' } else { chars[i - 1] };
                let is_symbol_start = prev == ' ' || prev == ',' || prev == '(' || prev == '[' || i == 0;
                if !is_symbol_start { return Some(i); }
            }
            _ => {}
        }
        i += 1;
    }
    None
}

/// Parse `key: value` pairs from a comma-separated options tail.
pub fn parse_options(s: &str) -> Vec<(String, String)> {
    let mut out: Vec<(String, String)> = Vec::new();
    for tok in split_top_level_commas(s) {
        let t = tok.trim();
        if t.is_empty() || t == "do" || t == "end" { continue; }
        if let Some(colon) = find_top_level_colon(t) {
            let key = t[..colon].trim().trim_end_matches(':').to_string();
            let val = t[colon + 1..].trim().trim_end_matches(')').trim().to_string();
            out.push((key, val));
        }
    }
    out
}

/// Parse `["a", "b"]` → `vec!["a", "b"]`.
pub fn parse_string_array(s: &str) -> Vec<String> {
    let t = s.trim().trim_start_matches('[').trim_end_matches(']').trim_end_matches(',');
    let mut out = Vec::new();
    for part in split_top_level_commas(t) {
        let v = strip_quotes(part.trim());
        if !v.is_empty() { out.push(v); }
    }
    out
}

/// Parse `{ "K" => "v", "K2" => "v2" }` → vec of pairs. Supports hash-
/// rocket and colon forms.
pub fn parse_hash_pairs(s: &str) -> Vec<(String, String)> {
    let t = s.trim().trim_start_matches('{').trim_end_matches('}');
    let mut out = Vec::new();
    for part in split_top_level_commas(t) {
        let pair = part.trim();
        if let Some(arrow) = pair.find("=>") {
            let k = strip_quotes(pair[..arrow].trim());
            let v = strip_quotes(pair[arrow + 2..].trim());
            out.push((k, v));
        } else if let Some(colon) = find_top_level_colon(pair) {
            let k = strip_quotes(pair[..colon].trim().trim_end_matches(':'));
            let v = strip_quotes(pair[colon + 1..].trim());
            out.push((k, v));
        }
    }
    out
}

/// Pick out `on :EventName` tokens from a joined adapter body.
pub fn extract_on_events(s: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut idx = 0;
    while idx < s.len() {
        if let Some(pos) = s[idx..].find("on :") {
            let start = idx + pos + 4;
            let end = s[start..].find(|c: char| !c.is_alphanumeric() && c != '_').unwrap_or(s.len() - start);
            let name = s[start..start + end].to_string();
            if !name.is_empty() { out.push(name); }
            idx = start + end;
        } else { break; }
    }
    out
}
