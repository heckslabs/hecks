//! The largest string a public request body may carry.
//!
//! Every kernel run feeds the whole world in and reads it all back (`wasm_runner`), and a string
//! a command argument carries is copied several times into that answer. Without a cap, a few
//! requests at the HTTP body limit grow the world past the kernel's output cap, and every later
//! command fails. `server::admit` checks a public request's body against it before anything is
//! dispatched; the internal protocol, from a peer on this host, is not capped.

use serde_json::Value;

/// 256 KiB: room for a long post body or an embedded document, small enough that one request
/// adds a bounded amount to every later kernel run.
pub const MAX_STRING_ARG_BYTES: usize = 256 * 1024;

/// The byte length of the longest string anywhere in `value`, when it is past
/// `MAX_STRING_ARG_BYTES`; `None` when every string fits.
pub fn oversized(value: &Value) -> Option<usize> {
    let longest = longest_string(value);
    (longest > MAX_STRING_ARG_BYTES).then_some(longest)
}

/// The byte length of the longest string anywhere in `value`.
fn longest_string(value: &Value) -> usize {
    match value {
        Value::String(text) => text.len(),
        Value::Array(items) => items.iter().map(longest_string).max().unwrap_or(0),
        Value::Object(fields) => fields.values().map(longest_string).max().unwrap_or(0),
        Value::Null | Value::Bool(_) | Value::Number(_) => 0,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn strings_within_the_cap_pass() {
        let body = json!({"name": "x".repeat(MAX_STRING_ARG_BYTES), "count": 3});
        assert_eq!(oversized(&body), None);
    }

    #[test]
    fn a_nested_string_past_the_cap_is_found_at_any_depth() {
        let body = json!({"with": {"tags": ["ok", "x".repeat(MAX_STRING_ARG_BYTES + 1)]}});
        assert_eq!(oversized(&body), Some(MAX_STRING_ARG_BYTES + 1));
    }
}
