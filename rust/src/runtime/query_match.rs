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
        crate::ir::WhereOp::NoneInState => true,
    }
}

pub(super) fn compare_strings(a: &str, b: &str) -> std::cmp::Ordering {
    if let (Ok(an), Ok(bn)) = (a.parse::<i64>(), b.parse::<i64>()) {
        return an.cmp(&bn);
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
    match cur {
        Value::Null => String::new(),
        Value::Map(m) if m.len() == 1 => m
            .get("value")
            .map(|v| v.to_string())
            .unwrap_or_else(|| cur.to_string()),
        _ => cur.to_string(),
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
