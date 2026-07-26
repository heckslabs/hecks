//! value — the runtime Value enum (the dynamic bag every aggregate is made
//! of) and the attrs! map-building macro. The CONVERSIONS live in
//! value_convert.rs ; this cask owns the type itself.
//!
//! Cask extracted VERBATIM from runtime/mod.rs (shrink-mod phase B, wave 3).
//!
//! [antibody-exempt: rust/src/runtime/value.rs — pure-utility core type (no
//!  domain), relocated verbatim from mod.rs blanket.]

use std::collections::HashMap;

/// Dynamic value — aggregates are bags of these
#[derive(Debug, Clone, PartialEq)]
pub enum Value {
    Str(String),
    Int(i64),
    Bool(bool),
    List(Vec<Value>),
    Map(HashMap<String, Value>),
    Null,
}

/// Macro for building attribute maps
#[macro_export]
macro_rules! attrs {
    ($($key:expr => $val:expr),* $(,)?) => {{
        let mut map = std::collections::HashMap::new();
        $(map.insert($key.to_string(), $val);)*
        map
    }};
}
