// Snippet: body of `primary_standards` — read primary's standards.md
// from the sibling `miette_family/chris/` directory and return its
// content as a single string. Empty when the file is missing so the
// `{{standards}}` placeholder substitutes to empty (boot stays alive).
//
// "Primary" is hard-coded to chris in this round — the role / primary
// marker shape is deferred to the onboarding flow (per the move plan).
// When that lands, the sibling-name "chris" becomes the resolved
// primary's identifier, and the path becomes computed.
//
// Specializer reads this with read_snippet_body (strips this header).
    if let Some(repo_root) = conception_dir.parent().and_then(|p| p.parent()) {
        let path = repo_root.join("miette_family/chris/standards.md");
        if let Ok(s) = fs::read_to_string(&path) {
            return s.trim_end().to_string();
        }
    }
    String::new()
