//! Free-function accessors over an `IR::Attribute#to_h`-shaped `Json::Object`, mirroring the
//! bare Hash lookups in rust/project/*.rb.

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
