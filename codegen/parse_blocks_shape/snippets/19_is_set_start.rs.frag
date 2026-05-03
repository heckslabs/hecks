/// Phase 2.c — returns true when `trimmed` starts a `set` statement
/// inside an on-block. Matches `set :attr, ...` (the Ruby positional
/// form with a Symbol literal) and `set "attr", ...` (string form).
/// The DSL surface today is `set :attr, value_spec` ; the string form
/// is supported defensively. Care taken not to false-match other
/// keywords starting with "set" (e.g. `set_inventory`) by requiring
/// whitespace after.
fn is_set_start(trimmed: &str) -> bool {
    trimmed.starts_with("set ") || trimmed.starts_with("set\t")
}

