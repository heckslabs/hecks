// Snippet: parse_family body. bucket-3 step 1 — parses one
// `Hecks.family "name" do ; verb "v" ; signal :s ; field :f ; secret :s ; end`
// block into a Family. Captures the quoted family name, then walks the
// inner lines, dispatching on the leading whitespace-delimited keyword
// (verb / signal / field / secret) so column-alignment spacing never breaks
// the match. `verb "..."` reads the quoted value ; signal/field/secret take
// the symbol token after the colon, terminating at the first whitespace,
// `#`, or `,` so the leading colon and any trailing comment/clause never
// ride into the IR. Each field carries a SOURCE the declaration FORM sets :
//   field  :timeout_ms            -> "direct" : the .world value IS the literal
//   field  :endpoint, from: :env  -> "env"    : the .world value is an env-var NAME
//   secret :token                 -> "secret" : env-var name, never logged
// The family's fields establish the schema its adapters' .world blocks conform to.
        fn sym_after(line: &str, keyword: &str) -> String {
            let rest = match line.strip_prefix(keyword) { Some(r) => r.trim_start(), None => return String::new() };
            let rest = rest.strip_prefix(':').unwrap_or(rest);
            let end = rest.find(|c: char| c.is_whitespace() || c == '#' || c == ',').unwrap_or(rest.len());
            rest[..end].trim().to_string()
        }
        // `field :x, from: :env` -> "env" ; `field :x` -> "direct". The source
        // the declaration FORM carries (secret is handled by its own arm).
        fn source_from_decl(line: &str) -> String {
            if let Some(idx) = line.find("from:") {
                let after = line[idx + "from:".len()..].trim_start();
                let after = after.strip_prefix(':').unwrap_or(after);
                let end = after.find(|c: char| c.is_whitespace() || c == '#' || c == ',').unwrap_or(after.len());
                let s = after[..end].trim();
                if !s.is_empty() { return s.to_string(); }
            }
            "direct".to_string()
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
                "field" => {
                    let name = sym_after(t, "field");
                    if !name.is_empty() {
                        family.fields.push(FamilyField { name, source: source_from_decl(t) });
                    }
                }
                "secret" => {
                    let name = sym_after(t, "secret");
                    if !name.is_empty() {
                        family.fields.push(FamilyField { name, source: "secret".to_string() });
                    }
                }
                _ => {}
            }
            i += 1;
        }
        (Some(family), i)
    