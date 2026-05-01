// Snippet: normalize_value body — sui-generis string-whitespace
// cleanup that doesn't fit a mapping_kind primitive. Referenced by
// the NormalizeValue fixture's snippet_path. The specializer
// interpolates this directly as the function body between { and }.
//
// Purpose (from hand-written dump.rs):
//   Strip whitespace adjacent to brackets/braces/parens. Source
//   representations differ ("[ a, b ]" vs "[a, b]") even when
//   semantically identical; both runtimes normalize so the canonical
//   output agrees.
    let mut out = String::with_capacity(s.len());
    let mut in_str = false;
    let mut prev = '\0';
    let chars: Vec<char> = s.chars().collect();
    for (i, &c) in chars.iter().enumerate() {
        match c {
            '"' if prev != '\\' => { in_str = !in_str; out.push(c); }
            ' ' | '\t' if !in_str => {
                let next = chars.get(i + 1).copied().unwrap_or('\0');
                let just_after_open = matches!(prev, '[' | '{' | '(');
                let just_before_close = matches!(next, ']' | '}' | ')');
                if !just_after_open && !just_before_close { out.push(c); }
            }
            _ => out.push(c),
        }
        prev = c;
    }
    out
