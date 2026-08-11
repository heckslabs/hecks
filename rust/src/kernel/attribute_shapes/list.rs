// Implements the `:list` branch of `Runtime::Value::Coercion::SHAPES`
// (lib/hecksagain/runtime/value/coercion.rb) — `Attribute#list?` /
// `for_attribute`'s `hydrate_entity_list` branch. At the
// expression-evaluation layer a list-typed field is represented by its
// own LENGTH ONLY (`Value::List(usize)`, `expr.rs`'s own header): real
// `given`/`ensures`/invariant text only ever asks `.size`/`.empty?` of a
// list field as a whole (never indexes into an element by expression),
// so there is nothing here beyond the two questions a bare length alone
// can answer — `expression_operators::sized` calls straight into these.

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
