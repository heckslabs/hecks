// Snippet: body of `primary_standards` — read primary's standards.md
// via heki::repo_root() (i163 fix : robust to bucket reorgs).
//
// "Primary" is hard-coded to chris in this round — the role / primary
// marker shape is deferred to the onboarding flow (per the move plan).
// When that lands, the sibling-name "chris" becomes the resolved
// primary's identifier, and the path becomes computed.
//
// Specializer reads this with read_snippet_body (strips this header).
    if let Some(hecks_root) = crate::heki::repo_root() {
        if let Some(projects_root) = hecks_root.parent() {
            let path = projects_root.join("miette_family/chris/standards.md");
            if let Ok(s) = fs::read_to_string(&path) {
                return s.trim_end().to_string();
            }
        }
    }
    String::new()
