// Snippet: body of `render` — the entrypoint that walks the template,
// substitutes vars, and writes the rendered prompt. Specializer reads
// this with read_snippet_body (strips this header).
    let mut vars = variables_for_being(being);
    vars.insert("standards", primary_standards(conception_dir));
    let template_path = template_path_for_being(conception_dir, being);

    let template = match fs::read_to_string(&template_path) {
        Ok(t) => t,
        Err(e) => {
            eprintln!(
                "  ⚠ system_prompt: template not found at {} ({})",
                template_path.display(), e
            );
            return 0;
        }
    };

    let rendered = substitute(&template, &vars);
    let dest = destination_for_being(conception_dir, being);

    match fs::write(&dest, &rendered) {
        Ok(_) => rendered.len(),
        Err(e) => {
            eprintln!(
                "  ⚠ system_prompt: write to {} failed ({})",
                dest.display(), e
            );
            0
        }
    }
