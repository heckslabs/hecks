/// Returns true when `trimmed` starts a `dispatch` statement (used by
/// the on-block walker before it joins continuation lines).
fn is_dispatch_start(trimmed: &str) -> bool {
    trimmed.starts_with("dispatch ")
        || trimmed.starts_with("dispatch\t")
        || trimmed.starts_with("dispatch\"")
}

