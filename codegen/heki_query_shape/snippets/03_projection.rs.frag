// ---------------------------------------------------------------------------
// Projection helpers
// ---------------------------------------------------------------------------

/// Render a scalar JSON value as a plain string. Strings lose their
/// quotes (shell-friendly); numbers/bools stringify themselves; nulls
/// become "". Objects/arrays compact-JSON.
pub fn field_to_string(v: Option<&serde_json::Value>) -> String {
    match v {
        None                               => String::new(),
        Some(serde_json::Value::Null)      => String::new(),
        Some(serde_json::Value::String(s)) => s.clone(),
        Some(serde_json::Value::Bool(b))   => b.to_string(),
        Some(serde_json::Value::Number(n)) => n.to_string(),
        Some(other)                        => other.to_string(),
    }
}

