/// Parse a .fixtures file from disk. Returns None on read failure —
/// the runner logs and continues (empty fixtures = old behavior).
pub fn parse_file(path: &str) -> Option<FixturesFile> {
    let source = std::fs::read_to_string(path).ok()?;
    Some(fixtures_parser::parse(&source))
}

