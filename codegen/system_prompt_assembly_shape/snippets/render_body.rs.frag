// Snippet: body of `render` — assembles the prompt from the per-being
// content fixtures, substitutes vars, writes the rendered prompt.
// Specializer reads this with read_snippet_body (strips this header).
    let mut vars = variables_for_being(being);
    vars.insert("standards", primary_standards(conception_dir));
    vars.insert("grammar", grammar_block());

    let fixtures_path = match content_fixtures_path_for_being(being) {
        Some(p) => p,
        None => {
            eprintln!("  ⚠ system_prompt: could not resolve content fixtures for {}", being);
            return 0;
        }
    };

    let source = match fs::read_to_string(&fixtures_path) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("  ⚠ system_prompt: content fixtures not found at {} ({})", fixtures_path.display(), e);
            return 0;
        }
    };

    let body = assemble_sections(&source);
    let rendered = substitute(&body, &vars);
    let dest = destination_for_being(conception_dir, being);

    match fs::write(&dest, &rendered) {
        Ok(_) => rendered.len(),
        Err(e) => {
            eprintln!("  ⚠ system_prompt: write to {} failed ({})", dest.display(), e);
            0
        }
    }
