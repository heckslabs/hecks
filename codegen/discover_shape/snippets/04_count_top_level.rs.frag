fn count_top_level_bluebooks(dir: &Path) -> usize {
    if !dir.is_dir() { return 0; }
    let mut n = 0;
    if let Ok(entries) = std::fs::read_dir(dir) {
        for entry in entries.flatten() {
            let p = entry.path();
            if p.is_file() && p.extension().map(|e| e == "bluebook").unwrap_or(false) {
                n += 1;
            }
        }
    }
    n
}

