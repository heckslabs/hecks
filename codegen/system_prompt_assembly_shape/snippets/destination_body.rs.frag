// Snippet: body of `destination_for_being` — resolves the per-being
// repo destination via heki::repo_root() (i163 fix). Falls back to
// the conception when the sibling repo isn't present (development /
// fresh-clone). Specializer reads this with read_snippet_body
// (strips this header).
    let stem = being.to_lowercase();

    if let Some(hecks_root) = crate::heki::repo_root() {
        if let Some(projects_root) = hecks_root.parent() {
            let sibling = projects_root.join(&stem).join("self/system_prompt.md");
            if let Some(parent) = sibling.parent() {
                if parent.is_dir() {
                    return sibling;
                }
            }
        }
    }

    // Fallback : write into the conception so a fresh-clone
    // environment still gets a prompt file. Same suffix the
    // pre-i117-Round-4 boot used.
    conception_dir.join(format!("system_prompt_{}.md", stem))
