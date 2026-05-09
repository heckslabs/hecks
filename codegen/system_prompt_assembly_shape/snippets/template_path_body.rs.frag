// Snippet: body of `template_path_for_being` — walks four candidate
// roots so neither the per-being repo move (i117 R4 W2) nor the
// i118 R3 W2 capabilities lift strands the resolver. Returns the
// first existing path ; falls back to the legacy in-conception path
// for diagnostic clarity when neither root resolves.
//
// Specializer reads this with read_snippet_body (strips this header).
    let stem = being.to_lowercase();
    let template_filename = format!("{}_prompt.md.template", stem);

    // Canonical : <projects>/<being>/self/system_prompt/system_prompt_assembly/
    if let Some(hecks_root) = crate::heki::repo_root() {
        if let Some(projects_root) = hecks_root.parent() {
            let new_home = projects_root
                .join(&stem)
                .join("self/system_prompt/system_prompt_assembly")
                .join(&template_filename);
            if new_home.exists() {
                return new_home;
            }
        }
    }

    // Legacy fallback : <conception>/capabilities/system_prompt_assembly/
    conception_dir
        .join("capabilities/system_prompt_assembly")
        .join(template_filename)
