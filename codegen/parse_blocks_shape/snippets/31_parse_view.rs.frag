/// Parse a `view "name" do ... end` block at aggregate scope (i254).
///
/// Lines inside the block are recognized as :
///
///   * `show :a, :b, :c`  — append the listed symbols to `fields`
///   * `show_all`         — set `show_all = true` (admin-style projection)
///   * `plus :x, :y`      — append the listed symbols to `fields`
///                          (typically used after `show_all`)
///
/// Other lines are absorbed silently so that future view sub-DSL (e.g.
/// `show ServiceAddress.gate_code, as: :gate_code` from i254's full
/// proposal) doesn't crash the parser before we wire it into the IR.
pub fn parse_view(lines: &[&str]) -> (View, usize) {
    let first = lines[0].trim();
    let name = extract_string(first).unwrap_or_default();
    let mut v = View { name, show_all: false, fields: vec![] };

    let mut i = 1;
    let mut depth = 1;
    while i < lines.len() && depth > 0 {
        let line = lines[i].trim();
        if line == "end" {
            depth -= 1;
            if depth == 0 { break; }
            i += 1;
            continue;
        }
        if depth == 1 {
            if line == "show_all" || line.starts_with("show_all ") {
                v.show_all = true;
            } else if line.starts_with("show") || line.starts_with("plus") {
                // Glue continuation lines : `show :a,\n     :b,\n     :c` is
                // one logical statement. Walk forward while the current line
                // ends with a comma, joining tails into one buffer before
                // splitting. The keyword prefix is stripped once at the head.
                let mut buf = String::new();
                let head_keyword_len = if line.starts_with("show") { 4 } else { 4 };
                buf.push_str(&line[head_keyword_len..]);
                while buf.trim_end().ends_with(',') && i + 1 < lines.len() {
                    i += 1;
                    buf.push(' ');
                    buf.push_str(lines[i].trim());
                }
                absorb_view_fields(&buf, &mut v.fields);
            } else if ends_with_do_block(line) {
                depth += 1;
            }
        } else if ends_with_do_block(line) {
            depth += 1;
        }
        i += 1;
    }
    (v, i + 1)
}

/// Pull `:sym, :sym, :sym` off a tail fragment from a `show` / `plus`
/// line, appending each symbol-name as a string into `fields`. Only
/// `:symbol` tokens are captured ; cross-aggregate join tokens like
/// `ServiceAddress.gate_code` (i249-tied) are ignored at the IR level
/// pending the references-in-views card. Tolerates trailing commas +
/// whitespace.
fn absorb_view_fields(tail: &str, fields: &mut Vec<String>) {
    for raw in tail.split(',') {
        let part = raw.trim().trim_end_matches(',').trim();
        if part.is_empty() { continue; }
        // Skip kwarg-style tail tokens like `as: :foo` — first segment
        // ends with `:` so we treat that whole segment as non-field.
        if part.ends_with(':') { continue; }
        // Only `:symbol` tokens are first-class own-field projections.
        if !part.starts_with(':') { continue; }
        let name = part.trim_start_matches(':').to_string();
        if !name.is_empty() {
            fields.push(name);
        }
    }
}

