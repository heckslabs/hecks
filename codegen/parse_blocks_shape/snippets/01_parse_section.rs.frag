/// Parse a top-level `section "Title" do … end` block from a capability
/// bluebook. Each `row "label", :field` line inside becomes one
/// SectionRow. Lines that aren't recognised are silently skipped so
/// authors can intersperse comments. Returns the parsed Section plus
/// the number of source lines consumed (including the closing `end`).
///
/// Form:
///   section "Identity" do
///     row "name",      :identity_name
///     row "born",      :born_at
///     row "age",       :age_str
///   end
///
/// `field` accepts both bare-symbol (`:foo`) and quoted string
/// (`"foo"`) tails so author intent reads naturally.
pub fn parse_section(lines: &[&str]) -> (Section, usize) {
    let first = lines[0].trim();
    let title = extract_string(first).unwrap_or_default();
    let mut rows: Vec<SectionRow> = Vec::new();
    let mut i = 1;
    let mut depth = 1usize;
    while i < lines.len() && depth > 0 {
        let line = lines[i].trim();
        if line == "end" {
            depth -= 1;
            if depth == 0 { break; }
            i += 1;
            continue;
        }
        if depth == 1 && (line.starts_with("row ") || line.starts_with("row\t")) {
            if let Some(row) = parse_section_row(line) {
                rows.push(row);
            }
        } else if ends_with_do_block(line) {
            depth += 1;
        }
        i += 1;
    }
    (Section { title, rows }, i + 1)
}

