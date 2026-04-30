// Snippet: body of `template_path_for_being` — pure path computation
// joining the conception root with the per-being template filename.
// Specializer reads this with read_snippet_body (strips this header).
    let stem = being.to_lowercase();
    conception_dir
        .join("capabilities/system_prompt_assembly")
        .join(format!("{}_prompt.md.template", stem))
