//! The largest string a command argument may carry.
//!
//! Every kernel run feeds the whole world in and reads it all back (`wasm_runner`), and a string
//! an argument carries is copied several times into that answer. Without a cap, a few requests
//! at the HTTP body limit grow the world past the kernel's output cap, and every later command
//! fails. The cap is checked before the step is journaled, so an oversized string never reaches
//! the journal or the world.

use serde_json::{json, Value};

/// 256 KiB: room for a long post body or an embedded document, small enough that one request
/// adds a bounded amount to every later kernel run.
pub const MAX_STRING_ARG_BYTES: usize = 256 * 1024;

/// The refusal, in the kernel's own `{"refusals": [...]}` shape, for a command whose arguments
/// hold a string longer than `MAX_STRING_ARG_BYTES`, at any depth; `None` when every string fits.
pub fn refusal(verb: &str, args: &Value) -> Option<Value> {
    let longest = longest_string(args);
    (longest > MAX_STRING_ARG_BYTES).then(|| {
        json!({"refusals": [{
            "verb": verb,
            "error": format!(
                "an argument is {longest} bytes; a string argument may be at most {MAX_STRING_ARG_BYTES} bytes"
            ),
            "kind": "ArgumentTooLarge",
        }]})
    })
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

    #[test]
    fn arguments_within_the_cap_are_not_refused() {
        let args = json!({"name": "x".repeat(MAX_STRING_ARG_BYTES), "count": 3});
        assert_eq!(refusal("Post.Publish", &args), None);
    }

    #[test]
    fn a_nested_string_past_the_cap_is_refused_in_the_kernels_shape() {
        let args = json!({"with": {"tags": ["ok", "x".repeat(MAX_STRING_ARG_BYTES + 1)]}});
        let refused = refusal("Post.Publish", &args).unwrap();
        assert_eq!(refused["refusals"][0]["verb"], "Post.Publish");
        assert_eq!(refused["refusals"][0]["kind"], "ArgumentTooLarge");
    }
}
