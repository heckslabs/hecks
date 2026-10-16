//! A JSON reader that accepts only what two parsers could not disagree about.
//!
//! The standard parsers keep the last of a repeated key and accept deep nesting. A token whose
//! header or claims repeat a key could be read one way here and another way by the issuer, so this
//! reader refuses it. It also keeps numbers apart from each other (an integer is not a float) because
//! the time claims must be integers.

use std::collections::HashMap;

/// A parsed JSON value, reduced to the shapes a token check needs to tell apart.
#[derive(Debug, Clone, PartialEq)]
pub enum Json {
    Null,
    Bool(bool),
    /// An integer; a digit string beyond the `i128` range saturates, which keeps every comparison
    /// against a time window the same as an unbounded integer would give.
    Int(i128),
    /// Any number that is not an integer literal (a fraction or an exponent).
    Number,
    Str(String),
    Array(Vec<Json>),
    Object(JsonObject),
}

/// A JSON object with unique keys.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct JsonObject(HashMap<String, Json>);

impl JsonObject {
    /// Finds a member by name.
    pub fn get(&self, name: &str) -> Option<&Json> {
        let _ = (&self.0, name);
        todo!("JsonObject::get")
    }

    /// Finds a member that is a string.
    pub fn get_str(&self, name: &str) -> Option<&str> {
        let _ = name;
        todo!("JsonObject::get_str")
    }

    /// Tells whether the member exists and is not JSON `null`.
    pub fn is_present(&self, name: &str) -> bool {
        let _ = name;
        todo!("JsonObject::is_present")
    }

    /// Lists the member names, in no particular order.
    pub fn keys(&self) -> impl Iterator<Item = &String> {
        self.0.keys()
    }
}

/// The deepest nesting accepted, counting the outer object as depth 1.
pub const MAX_DEPTH: usize = 8;

/// Parses `bytes` as one JSON object and nothing else.
///
/// Returns `None` for invalid UTF-8, invalid JSON, trailing text, a value that is not an object,
/// an object that repeats a key at any depth, and nesting deeper than [`MAX_DEPTH`].
pub fn parse_object(bytes: &[u8]) -> Option<JsonObject> {
    let _ = bytes;
    todo!("parse_object")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(text: &str) -> Option<JsonObject> {
        parse_object(text.as_bytes())
    }

    #[test]
    fn an_object_parses_and_its_members_are_readable() {
        let object = parse(r#"{"a":"x","b":7,"c":true,"d":null}"#).expect("object");
        assert_eq!(object.get_str("a"), Some("x"));
        assert_eq!(object.get("b"), Some(&Json::Int(7)));
        assert_eq!(object.get("c"), Some(&Json::Bool(true)));
        assert!(!object.is_present("d"));
        assert!(!object.is_present("missing"));
    }

    #[test]
    fn a_repeated_key_is_refused_at_the_top_and_when_nested() {
        assert!(parse(r#"{"a":1,"a":2}"#).is_none());
        assert!(parse(r#"{"a":{"b":1,"b":1}}"#).is_none());
        assert!(parse(r#"{"a":[{"b":1,"b":1}]}"#).is_none());
    }

    #[test]
    fn only_an_object_is_accepted() {
        for text in ["[]", "\"s\"", "1", "true", "null", "", "   ", "{", "{}x", "{} {}"] {
            assert!(parse(text).is_none(), "{text:?} must be refused");
        }
        assert!(parse("{}").is_some());
        assert!(parse(" {} ").is_some());
    }

    #[test]
    fn invalid_utf8_is_refused() {
        assert!(parse_object(b"{\"a\":\"\xff\"}").is_none());
    }

    #[test]
    fn integers_and_other_numbers_are_told_apart() {
        let object = parse(r#"{"i":-5,"f":1.5,"e":1e2,"z":1.0,"big":99999999999999999999999999999999999999999999}"#).expect("object");
        assert_eq!(object.get("i"), Some(&Json::Int(-5)));
        assert_eq!(object.get("f"), Some(&Json::Number));
        assert_eq!(object.get("e"), Some(&Json::Number));
        assert_eq!(object.get("z"), Some(&Json::Number));
        assert_eq!(object.get("big"), Some(&Json::Int(i128::MAX)));
    }

    #[test]
    fn nesting_is_capped_at_eight_levels() {
        let ok = format!("{}{}{}", r#"{"a":"#.repeat(1), "[".repeat(7) + &"]".repeat(7), "}");
        assert!(parse(&ok).is_some(), "depth 8 is allowed");
        let deep = format!("{}{}{}", r#"{"a":"#, "[".repeat(8) + &"]".repeat(8), "}");
        assert!(parse(&deep).is_none(), "depth 9 is refused");
    }
}
