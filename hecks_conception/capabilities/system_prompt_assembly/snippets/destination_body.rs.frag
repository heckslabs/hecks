// Snippet: body of `destination_for_being` — resolves the per-being
// repo destination, falling back to the conception root when the
// sibling repo isn't present (development/test environments). Mixed
// pure/IO : the `parent.is_dir()` check IS filesystem I/O, but it's
// guarded so the function still has deterministic output for any
// given filesystem state. Specializer reads this with read_snippet_body
// (strips this header).
    let stem = being.to_lowercase();
    if let Some(repo_root) = conception_dir.parent().and_then(|p| p.parent()) {
        let sibling = repo_root.join(&stem).join("self/system_prompt.md");
        if let Some(parent) = sibling.parent() {
            if parent.is_dir() {
                return sibling;
            }
        }
    }
    // Fallback : write into the conception so a fresh-clone
    // environment still gets a prompt file. Same suffix the
    // pre-i117-Round-4 boot used.
    if being == "Miette" {
        conception_dir.join(format!("system_prompt_{}.md", stem))
    } else {
        conception_dir.join(format!("system_prompt_{}.md", stem))
    }
