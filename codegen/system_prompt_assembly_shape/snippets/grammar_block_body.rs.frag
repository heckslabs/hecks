// Snippet: body of `grammar_block` — project {{grammar}} from the
// language/grammar bluebooks (one name-sorted bullet per grammar).
    let dir = match crate::heki::repo_root() {
        Some(root) => root.join("hecks_conception/aggregates/language/grammar"),
        None => return String::new(),
    };
    let mut bullets: Vec<String> = Vec::new();
    if let Ok(entries) = fs::read_dir(&dir) {
        for entry in entries.flatten() {
            let path = entry.path();
            if path.extension().and_then(|e| e.to_str()) != Some("bluebook") {
                continue;
            }
            if let Ok(src) = fs::read_to_string(&path) {
                if let (Some(name), Some(vision)) = (
                    quoted_after(&src, "Hecks.bluebook \""),
                    quoted_after(&src, "vision \""),
                ) {
                    bullets.push(format!("- **{}** — {}", name, vision));
                }
            }
        }
    }
    bullets.sort();
    bullets.join("\n")
