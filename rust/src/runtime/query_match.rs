use super::*;

pub fn repo_key(context: Option<&str>, name: &str) -> String {
    match context {
        Some(ctx) => format!("{}::{}", ctx, name),
        None => name.to_string(),
    }
}

pub fn where_matches(
    state: &AggregateState,
    clause: &crate::ir::WhereClause,
    attrs: &std::collections::HashMap<String, String>,
) -> bool {
    let target = resolve_where_value(&clause.value, attrs);
    let actual = resolve_state_field(state, &clause.field);
    match clause.op {
        crate::ir::WhereOp::Eq => actual == target,
        crate::ir::WhereOp::Ne => actual != target,
        crate::ir::WhereOp::Gt => compare_strings(&actual, &target).is_gt(),
        crate::ir::WhereOp::Gte => !compare_strings(&actual, &target).is_lt(),
        crate::ir::WhereOp::Lt => compare_strings(&actual, &target).is_lt(),
        crate::ir::WhereOp::Lte => !compare_strings(&actual, &target).is_gt(),
        crate::ir::WhereOp::In => target.split(',').any(|item| item.trim() == actual),
        crate::ir::WhereOp::Contains => match state.fields.get(&clause.field) {
            Some(Value::List(items)) => items.iter().any(|v| v.to_string() == target),
            Some(Value::Str(csv)) => csv.split(',').any(|x| x.trim() == target),
            _ => false,
        },
    }
}

pub(super) fn compare_strings(a: &str, b: &str) -> std::cmp::Ordering {
    if let (Ok(an), Ok(bn)) = (a.parse::<i64>(), b.parse::<i64>()) {
        return an.cmp(&bn);
    }
    // A FLOAT IS A NUMBER TOO. Parsing only i64 sent `2.5` down the byte-compare
    // path, where '2' < '3' happens to be right and '10.0' < '9.0' is not.
    if let (Ok(an), Ok(bn)) = (a.parse::<f64>(), b.parse::<f64>()) {
        if let Some(ordering) = an.partial_cmp(&bn) {
            return ordering;
        }
    }
    a.cmp(b)
}

pub(super) fn resolve_state_field(state: &AggregateState, field: &str) -> String {
    let mut parts = field.split('.');
    let head = match parts.next() {
        Some(h) => h,
        None => return String::new(),
    };
    let mut cur = match state.fields.get(head) {
        Some(v) => v,
        None => return String::new(),
    };
    for key in parts {
        match cur {
            Value::Map(m) => match m.get(key) {
                Some(v) => cur = v,
                None => return String::new(),
            },
            _ => return String::new(),
        }
    }
    scalar_reading(cur)
}

/// THE SCALAR A VALUE OBJECT STANDS FOR.
///
/// This read a one-key map by the literal key `"value"` and nothing else, so
/// `{"cents":2500}` — Money, Price, every amount in the corpus — fell through to
/// `Display for Value::Map`, which renders `"{1 fields}"`. Byte-compared against
/// `"2500"` that puts `'{'` (0x7B) above every digit, so Gt was ALWAYS true and
/// Lt ALWAYS false, whatever the number was.
///
/// The rule is `query_number`'s (dispatcher.rs): EXACTLY ONE numeric member, any
/// key name. Not Ruby's `comparable`, which takes the first numeric in insertion
/// order — `Value::Map` is a HashMap here, so "first" would be a coin flip on any
/// object with two numbers. Requiring exactly one is deterministic, and agrees
/// with Ruby wherever at most one member is numeric, which is every value object
/// the corpus declares.
///
/// Unwrapping any single-field map subsumes the old `"value"` case rather than
/// special-casing it.
fn scalar_reading(value: &Value) -> String {
    match value {
        Value::Null => String::new(),
        Value::Map(fields) => {
            let numbers: Vec<&Value> = fields
                .values()
                .filter(|held| matches!(held, Value::Int(_) | Value::Float(_)))
                .collect();

            match numbers.as_slice() {
                [only] => only.to_string(),
                _ if fields.len() == 1 => fields
                    .values()
                    .next()
                    .map(ToString::to_string)
                    .unwrap_or_default(),
                _ => value.to_string(),
            }
        }
        _ => value.to_string(),
    }
}

pub(super) fn resolve_where_value(
    value: &str,
    attrs: &std::collections::HashMap<String, String>,
) -> String {
    if let Some(kwarg) = value.strip_prefix(':') {
        return attrs.get(kwarg).cloned().unwrap_or_default();
    }
    value.to_string()
}

pub(super) fn resolve_limit_value(
    value: &str,
    attrs: &std::collections::HashMap<String, String>,
) -> Option<usize> {
    if let Some(kwarg) = value.strip_prefix(':') {
        return attrs.get(kwarg).and_then(|s| s.parse::<usize>().ok());
    }
    value.parse::<usize>().ok()
}
