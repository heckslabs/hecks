/// Macro for building attribute maps
#[macro_export]
macro_rules! attrs {
    ($($key:expr => $val:expr),* $(,)?) => {{
        let mut map = std::collections::HashMap::new();
        $(map.insert($key.to_string(), $val);)*
        map
    }};
}

