// Snippet: is_binding_line predicate. bucket-3 step 2 — recognises a
// hexagon bind `Aggregate::Path.verb(...)` so the parse loop can capture
// it without a fixed `starts_with` prefix (the leading FQN varies). The
// token before `::` must be an uppercase-led alphanumeric word, and the
// line must carry a `.verb(` call. Keyword forms never match : `Hecks.*`
// has no `::` ; adapter / gate / subscribe / driven / driving are
// lowercase-led (and consumed by earlier dispatches anyway).
    let t = line.trim();
    match t.find("::") {
        Some(idx) if idx > 0 => {
            let head = &t[..idx];
            head.starts_with(|c: char| c.is_ascii_uppercase())
                && head.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
                && t.contains('.')
                && t.contains('(')
        }
        _ => false,
    }
