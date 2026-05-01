/// Strip a leading `#!...\n` shebang line if present.
///
/// Bluebooks carrying `#!/usr/bin/env hecks-life run` at the top should
/// parse identically to the same file without that line. Everything
/// after the first newline passes through untouched.
pub fn strip_shebang(source: &str) -> &str {
    if source.starts_with("#!") {
        if let Some(nl) = source.find('\n') {
            return &source[nl + 1..];
        }
        return "";
    }
    source
}

