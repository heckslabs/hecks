/// Convenience: locate + parse. Returns None when no sibling file
/// exists.
pub fn find_for(behaviors_path: &str) -> Option<FixturesFile> {
    let path = locate_path(behaviors_path)?;
    parse_file(&path)
}

