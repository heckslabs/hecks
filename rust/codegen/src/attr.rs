//! Small accessors over an `IR::Attribute#to_h`-shaped `Json::Object` —
//! the JSON-round-tripped shape rust/project/*.rb reads via `attr[:name]`
//! etc. Kept as free functions over `&Json` rather than a wrapper struct:
//! every Ruby call site is a bare Hash lookup, and mirroring that directly
//! keeps this file trivially diffable against the Ruby source rather than
//! introducing a struct shape the Ruby original never had.

use crate::json::Json;

pub fn name(attr: &Json) -> &str {
    attr.get("name").and_then(Json::as_str).unwrap_or("")
}

pub fn type_name(attr: &Json) -> &str {
    attr.get("type").and_then(Json::as_str).unwrap_or("")
}

pub fn list(attr: &Json) -> bool {
    attr.get("list").map(Json::as_bool).unwrap_or(false)
}

pub fn optional(attr: &Json) -> bool {
    attr.get("optional").map(Json::as_bool).unwrap_or(false)
}

pub fn default(attr: &Json) -> Option<&Json> {
    attr.get("default")
}

pub fn pattern(attr: &Json) -> Option<&str> {
    attr.get("pattern").and_then(Json::as_str)
}

pub fn admits(attr: &Json) -> Option<&str> {
    attr.get("admits").and_then(Json::as_str)
}
