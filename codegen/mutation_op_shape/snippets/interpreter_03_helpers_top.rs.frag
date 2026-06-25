/// Numeric read of a state field, used by Multiply/Decay/Clamp. Falls
/// back to 0.0 when the field is unset or non-numeric — matches the
/// existing increment_float behaviour.
fn field_numeric(field: &str, state: &AggregateState) -> f64 {
    numeric_value(state.get(field)).unwrap_or(0.0)
}

/// Read [min, max] from a Value::List of two numeric elements. Returns
/// None when the shape doesn't fit — caller treats that as a no-op.
fn clamp_bounds(v: &Value) -> Option<(f64, f64)> {
    if let Value::List(items) = v {
        if items.len() == 2 {
            let lo = numeric_value(&items[0])?;
            let hi = numeric_value(&items[1])?;
            return Some((lo.min(hi), lo.max(hi)));
        }
    }
    None
}

