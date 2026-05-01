pub fn parse_lifecycle(lines: &[&str]) -> (Lifecycle, usize) {
    let first = lines[0].trim();
    let field = extract_symbol(first).unwrap_or_default();
    // `default:` accepts a quoted string OR a bare token (`true`, `false`,
    // `:symbol`) — match the Ruby DSL which stringifies any of these.
    let default = if first.contains("default:") {
        let after = extract_after(first, "default:").unwrap_or_default();
        extract_state_token(&after).unwrap_or_default()
    } else { String::new() };

    let mut transitions = vec![];
    let mut i = 1;
    while i < lines.len() {
        let line = lines[i].trim();
        if line == "end" { break; }
        if line.starts_with("transition") {
            if let Some(cmd) = extract_string(line) {
                // to_state: token after `=>` — quoted, bare, or `:symbol`.
                let to_state = line
                    .find("=>")
                    .and_then(|arrow| extract_state_token(&line[arrow + 2..]));
                // Collect ALL from states. `from: "a"` → [Some("a")];
                // `from: ["a", "b"]` → [Some("a"), Some("b")]; absent → [None].
                // Bare tokens (`true`/`false`/`:sym`) also accepted.
                let from_states: Vec<Option<String>> = if line.contains("from:") {
                    let after = extract_after(line, "from:").unwrap_or_default();
                    let trimmed = after.trim_start();
                    if trimmed.starts_with('[') {
                        // Array form — split on commas inside the brackets and
                        // extract a state token from each element.
                        let close = trimmed.find(']').unwrap_or(trimmed.len());
                        let inner = &trimmed[1..close];
                        let found: Vec<Option<String>> = inner
                            .split(',')
                            .filter_map(|part| extract_state_token(part).map(Some))
                            .collect();
                        if found.is_empty() { vec![None] } else { found }
                    } else {
                        vec![extract_state_token(&after)]
                    }
                } else { vec![None] };
                if let Some(to) = to_state {
                    for from_state in from_states {
                        transitions.push(Transition {
                            command: cmd.clone(), to_state: to.clone(), from_state
                        });
                    }
                }
            }
        }
        i += 1;
    }
    (Lifecycle { field, default, transitions }, i + 1)
}

