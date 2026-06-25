
/// Parse an aggregate-level `invariant "name" do holds_when { <pred> } end`
/// block (f4). The first line carries the rule name (a quoted string) ; the
/// `holds_when { ... }` line inside carries the predicate, extracted with the
/// same `{ ... }` block grammar a single-line `given` uses. Returns the
/// parsed Invariant (None when the name or predicate is missing/unparseable)
/// plus the number of source lines consumed including the closing `end`.
///
/// Form:
///   invariant "ready_means_verified" do
///     holds_when { state != "done" || verified == true }
///   end
///
/// Predicates are single-line — the same constraint a `given` carries, since
/// both flow through the same line-scanning expression grammar.
pub fn parse_invariant(lines: &[&str]) -> (Option<Invariant>, usize) {
    let first = lines[0].trim();
    let name = extract_string(first).unwrap_or_default();
    let mut expression: Option<String> = None;
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
        if depth == 1 && line.starts_with("holds_when") {
            expression = extract_block(line);
        } else if ends_with_do_block(line) {
            depth += 1;
        }
        i += 1;
    }
    let consumed = i + 1;
    match (name.is_empty(), expression) {
        (false, Some(expr)) => (Some(Invariant { name, expression: expr }), consumed),
        _ => (None, consumed),
    }
}
