// Snippet: body of `pizzas_block` — project {{pizzas}} from
// examples/pizzas/bluebook (full source, fenced per file, ordered
// domain -> hexagon -> families -> adapters -> world).
    let dir = match crate::heki::repo_root() {
        Some(root) => root.join("examples/pizzas/bluebook"),
        None => return String::new(),
    };
    fn rank(ext: &str) -> u8 {
        match ext {
            "bluebook" => 0,
            "hecksagon" => 1,
            "family" => 2,
            "adapter" => 3,
            "world" => 4,
            _ => 5,
        }
    }
    let mut files: Vec<(u8, String, String)> = Vec::new();
    if let Ok(entries) = fs::read_dir(&dir) {
        for entry in entries.flatten() {
            let path = entry.path();
            let ext = match path.extension().and_then(|e| e.to_str()) {
                Some(e) => e.to_string(),
                None => continue,
            };
            if !matches!(
                ext.as_str(),
                "bluebook" | "hecksagon" | "family" | "adapter" | "world"
            ) {
                continue;
            }
            let name = match path.file_name().and_then(|n| n.to_str()) {
                Some(n) => n.to_string(),
                None => continue,
            };
            if let Ok(src) = fs::read_to_string(&path) {
                files.push((rank(&ext), name, src));
            }
        }
    }
    files.sort_by(|a, b| a.0.cmp(&b.0).then(a.1.cmp(&b.1)));
    files
        .iter()
        .map(|(_, name, src)| format!("### `{}`\n\n```\n{}\n```", name, src.trim_end()))
        .collect::<Vec<_>>()
        .join("\n\n")
