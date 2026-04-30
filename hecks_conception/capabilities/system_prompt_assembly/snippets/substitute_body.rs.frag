// Snippet: body of `substitute` — the {{key}} scanner. Pure but
// iterative state-machine over `{{` and `}}` markers, emitted as
// an inline static helper (the same shape `normalize_value` uses
// in dump.rs). Specializer reads this with read_snippet_body
// (strips this header).
    let mut out = String::with_capacity(template.len() + 32);
    let mut rest = template;
    while let Some(open) = rest.find("{{") {
        out.push_str(&rest[..open]);
        let after_open = &rest[open + 2..];
        let close = match after_open.find("}}") {
            Some(c) => c,
            None => {
                // Malformed — emit literal and stop scanning.
                out.push_str(&rest[open..]);
                return out;
            }
        };
        let key = after_open[..close].trim();
        if let Some(val) = vars.get(key) {
            out.push_str(val);
        } else {
            // Unknown key — preserve literally so reviewers see it.
            out.push_str("{{");
            out.push_str(key);
            out.push_str("}}");
        }
        rest = &after_open[close + 2..];
    }
    out.push_str(rest);
    out
