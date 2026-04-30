/// Parse a fixture attribute value from its source-token form. Same
/// shape as behaviors_runner::parse_value but extended for the list
/// literals that .fixtures files commonly carry (`linked: ["a","b"]`).
fn parse_fixture_value(raw: &str) -> Value {
    let s = raw.trim();
    if s.starts_with('[') && s.ends_with(']') {
        let inner = &s[1..s.len() - 1];
        let items: Vec<Value> = inner.split(',')
            .map(|p| p.trim().trim_matches('"').trim_matches('\''))
            .filter(|p| !p.is_empty())
            .map(|p| Value::Str(p.to_string()))
            .collect();
        return Value::List(items);
    }
    if let Ok(n) = s.parse::<i64>() { return Value::Int(n); }
    if s == "true"  { return Value::Bool(true); }
    if s == "false" { return Value::Bool(false); }
    Value::Str(s.to_string())
}
