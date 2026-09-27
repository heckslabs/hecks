// The `:list` shape of `Runtime::Value::Coercion::SHAPES`.
// Expressions see a list as its length only (`Value::List(usize)`): just `size` and `empty?`.

use crate::kernel::expr::Value;

pub fn is_empty(v: &Value) -> Option<bool> {
    match v {
        Value::List(n) => Some(*n == 0),
        _ => None,
    }
}

pub fn size(v: &Value) -> Option<i64> {
    match v {
        Value::List(n) => Some(*n as i64),
        _ => None,
    }
}
