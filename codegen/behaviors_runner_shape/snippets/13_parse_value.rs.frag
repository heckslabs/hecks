fn parse_value(s: &str) -> Value {
    if let Ok(n) = s.parse::<i64>() { return Value::Int(n); }
    if s == "true" { return Value::Bool(true); }
    if s == "false" { return Value::Bool(false); }
    Value::Str(s.to_string())
}

