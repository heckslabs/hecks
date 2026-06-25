// A kwarg looks like `key: value` where `key` is a lowercase identifier.
// Distinguishes `default: true` (kwarg) from `String` or `MyVO` (positional type).
fn is_kwarg(s: &str) -> bool {
    let Some(colon_pos) = s.find(':') else { return false; };
    let before = &s[..colon_pos];
    !before.is_empty()
        && before.chars().next().map_or(false, |c| c.is_ascii_lowercase())
        && before.chars().all(|c| c.is_alphanumeric() || c == '_')
}

