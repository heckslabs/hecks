fn current_numeric(v: Option<&Value>) -> f64 {
    match v {
        Some(Value::Int(n)) => *n as f64,
        Some(Value::Str(s)) => s.parse::<f64>().unwrap_or(0.0),
        _ => 0.0,
    }
}

/// Format a numeric value for storage. Whole-valued floats stringify
/// as "3" (not "3.0") so they keep parity with Int(3) for downstream
/// equality comparisons; fractional values keep their decimal form.
fn format_numeric(n: f64) -> String {
    if n == n.trunc() && n.abs() < 1e15 {
        format!("{}", n as i64)
    } else {
        format!("{}", n)
    }
}
