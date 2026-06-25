/// Parse one `row "label", :field` line. Field tail may be a bare
/// symbol (`:awareness_carrying`), a quoted string (`"awareness_carrying"`),
/// or a bare identifier. Returns None when the line shape is unparseable.
pub fn parse_section_row(line: &str) -> Option<SectionRow> {
    let label = extract_string(line)?;
    let after_label_close = {
        let first_open = line.find('"')?;
        let after = &line[first_open + 1..];
        let close = after.find('"')?;
        first_open + 1 + close + 1
    };
    let tail = line[after_label_close..].trim_start_matches(',').trim();
    let field = if tail.starts_with('"') {
        extract_string(tail)?
    } else if tail.starts_with(':') {
        extract_symbol(tail)?
    } else {
        // bare identifier — first contiguous run
        let end = tail.find(|c: char| !c.is_alphanumeric() && c != '_')
            .unwrap_or(tail.len());
        let f = tail[..end].trim();
        if f.is_empty() { return None; }
        f.to_string()
    };
    Some(SectionRow { label, field })
}

