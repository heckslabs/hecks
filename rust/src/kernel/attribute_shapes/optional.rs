// The `:optional` shape of `Runtime::Value::Coercion::SHAPES`.
// `Value::Nil` covers both an unset `optional:` field and a literal `nil`, as in Ruby.

use crate::kernel::expr::Value;

// `nil.to_s == ""`; `None` for anything but `Value::Nil`.
pub fn to_s(v: &Value) -> Option<Value> {
    matches!(v, Value::Nil).then(|| Value::Str(String::new()))
}
