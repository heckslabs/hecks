//! The patterns a bluebook names instead of spelling: `matches: :snake_name` stands for exactly
//! its regex. Mirrors `Hecks::Bluebook::NamedPattern`; spec/named_pattern_spec.rb holds the two
//! tables to each other.

/// Name => the regex source it stands for.
const TABLE: &[(&str, &str)] = &[
    ("present", r"[^ \t\n\r]"),
    ("not_empty", r"[^\t\n\r]"),
    ("no_whitespace", r"^[^ \t\n\r]+$"),
    ("snake_name", r"^[a-z][a-z0-9_]*$"),
    ("git_sha", r"^[0-9a-fA-F]{7,40}$"),
    ("digits", r"^[0-9]+$"),
];

/// The regex source `name` stands for, or `None` when the language gives no such name.
pub fn source(name: &str) -> Option<&'static str> {
    TABLE.iter().find(|(given, _)| *given == name).map(|(_, source)| *source)
}

/// Every name the language gives, in table order.
pub fn names() -> Vec<&'static str> {
    TABLE.iter().map(|(name, _)| *name).collect()
}
