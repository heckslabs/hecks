/// Returns the absolute path of the fixtures file matching the given
/// `.behaviors` (or `_behavioral_tests.bluebook`) path, or None if
/// nothing matches. Public so the runner can log which file loaded.
pub fn locate_path(behaviors_path: &str) -> Option<String> {
    let p = PathBuf::from(behaviors_path);
    let stem_raw = p.file_stem()?.to_str()?;
    // Strip the `_behavioral_tests` trailer if the caller passed the
    // pre-split-out form (rare — most call sites pass the .behaviors
    // name, whose file_stem is already the domain stem).
    let stem = stem_raw.trim_end_matches("_behavioral_tests");
    let parent = p.parent().map(|q| q.to_path_buf())
        .unwrap_or_else(|| PathBuf::from("."));

    let candidates = [
        parent.join(format!("{}.fixtures", stem)),
        parent.join("fixtures").join(format!("{}.fixtures", stem)),
    ];
    candidates.iter()
        .find(|c| c.is_file())
        .map(|c| c.to_string_lossy().into_owned())
}

