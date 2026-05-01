/// i142 Tier 2 — compose the HashMap key for a repository.
/// Same-name aggregates in different bounded contexts get distinct
/// keys ("Library::Inbox" vs "Workshop::Inbox") so they end up with
/// distinct Repository instances and distinct .heki paths.
/// Legacy aggregates without a context use their bare name.
pub fn repo_key(context: Option<&str>, name: &str) -> String {
    match context {
        Some(ctx) => format!("{}::{}", ctx, name),
        None => name.to_string(),
    }
}

