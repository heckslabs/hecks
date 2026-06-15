// Snippet: parse_family body. bucket-3 step 1 — parses one
// `Hecks.family "name" do ; verb "v" ; signal :s ; field :f ; end`
// block into a Family. Captures the quoted family name, then walks the
// inner lines, dispatching on the leading whitespace-delimited keyword
// (verb / signal / field) so column-alignment spacing never breaks the
// match. `verb "..."` reads the quoted value ; signal/field take the
// symbol token after the colon, terminating at the first whitespace-or-
// `#` so the leading colon and any trailing comment never ride into the
// IR (stored "reply"/"dir", matching the persistence-kind convention
// "memory", not ":memory").
    fn sym_after(line: &str, keyword: &str) -> String {
        let rest = match line.strip_prefix(keyword) { Some(r) => r.trim_start(), None => return String::new() };
        let rest = rest.strip_prefix(':').unwrap_or(rest);
        let end = rest.find(|c: char| c.is_whitespace() || c == '#').unwrap_or(rest.len());
        rest[..end].trim().to_string()
    }
    let first = lines[0].trim();
    let name = match between_quotes(first) { Some(n) => n, None => return (None, 1) };
    let mut family = Family { name, verb: String::new(), signal: String::new(), fields: Vec::new() };
    let mut i = 1;
    while i < lines.len() {
        let t = lines[i].trim();
        if t == "end" { return (Some(family), i + 1); }
        if t.is_empty() || t.starts_with('#') { i += 1; continue; }
        match t.split_whitespace().next().unwrap_or("") {
            "verb" => { if let Some(v) = between_quotes(t) { family.verb = v; } }
            "signal" => { family.signal = sym_after(t, "signal"); }
            "field" => { let f = sym_after(t, "field"); if !f.is_empty() { family.fields.push(f); } }
            _ => {}
        }
        i += 1;
    }
    (Some(family), i)
