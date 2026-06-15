// Snippet: parse_adapter_decl body. bucket-3 step 1 — parses one
// `Hecks.adapter "Name" do ; family "fam" ; end` block into an Adapter
// (the inverted arrow : the adapter declares the family it implements ;
// the family never names the adapter). Captures the quoted adapter name,
// then the quoted `family "..."` line — dispatched on the leading
// whitespace-delimited keyword so column-alignment spacing never breaks
// the match.
    let first = lines[0].trim();
    let name = match between_quotes(first) { Some(n) => n, None => return (None, 1) };
    let mut adapter = Adapter { name, family: String::new() };
    let mut i = 1;
    while i < lines.len() {
        let t = lines[i].trim();
        if t == "end" { return (Some(adapter), i + 1); }
        if t.is_empty() || t.starts_with('#') { i += 1; continue; }
        if t.split_whitespace().next() == Some("family") {
            if let Some(f) = between_quotes(t) { adapter.family = f; }
        }
        i += 1;
    }
    (Some(adapter), i)
