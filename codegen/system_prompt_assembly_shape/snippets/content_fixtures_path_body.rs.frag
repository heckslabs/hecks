// Snippet: body of `content_fixtures_path_for_being` — resolves the
// per-being content fixtures path via heki::repo_root().
    let stem = being.to_lowercase();
    let hecks_root = crate::heki::repo_root()?;
    let projects_root = hecks_root.parent()?;
    Some(projects_root.join(&stem).join("self/system_prompt/system_prompt_content.fixtures"))
