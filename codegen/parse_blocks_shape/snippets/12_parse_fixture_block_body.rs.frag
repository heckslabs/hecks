/// Parse the body of a block-form fixture. `lines` starts at the line AFTER
/// `fixture "X" do`; parsing stops at the matching `end`. Inside, the
/// `aggregate "X"` line sets the aggregate name; every other `key "value"`
/// line becomes an attribute (string-typed, unwrapped). Returns the parsed
/// fields and the number of lines consumed (including the closing `end`).
pub fn parse_fixture_block_body(lines: &[&str]) -> (String, Vec<(String, String)>, usize) {
    let mut aggregate_name = String::new();
    let mut attributes: Vec<(String, String)> = vec![];
    let mut depth = 1usize;
    let mut i = 0;
    while i < lines.len() && depth > 0 {
        let l = lines[i].trim();
        if l == "end" {
            depth -= 1;
            if depth == 0 { i += 1; break; }
        } else if ends_with_do_block(l) {
            depth += 1;
        } else if depth == 1 && !l.is_empty() && !l.starts_with('#') {
            // First-token dispatch: `aggregate "X"` sets the type; any other
            // identifier `key "value"` (or bare value) becomes an attribute.
            let token_end = l.find(|c: char| c.is_whitespace()).unwrap_or(l.len());
            let key = &l[..token_end];
            let rest = l[token_end..].trim();
            if key == "aggregate" {
                aggregate_name = extract_string(rest).unwrap_or_default();
            } else if !key.is_empty() && key.chars().next().map_or(false, |c| c.is_ascii_lowercase()) {
                let val = if rest.starts_with('"') {
                    extract_string(rest).unwrap_or_else(|| rest.to_string())
                } else {
                    rest.to_string()
                };
                attributes.push((key.to_string(), val));
            }
        }
        i += 1;
    }
    (aggregate_name, attributes, i)
}

