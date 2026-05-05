pub fn parse_value_object(lines: &[&str]) -> (ValueObject, usize) {
    let first = lines[0].trim();
    let name = extract_string(first).unwrap_or_default();
    let mut vo = ValueObject { name, description: None, attributes: vec![] };

    let mut i = 1;
    let mut depth = 1;
    while i < lines.len() && depth > 0 {
        let line = lines[i].trim();
        if line == "end" {
            depth -= 1;
            if depth == 0 { break; }
        } else if depth == 1 && (line.starts_with("rule ") || line.starts_with("rule\t")) {
            // i259 — `rule "..." do ... end` on a value_object delegates
            // to consume_rule_block so a multi-statement `requires` body
            // can't decrement the surrounding depth.
            let consumed = consume_rule_block(&lines[i..]);
            i += consumed;
            continue;
        } else if ends_with_do_block(line) {
            depth += 1;
        }
        if depth == 1 {
            if line.starts_with("description") { vo.description = extract_string(line); }
            if line.starts_with("attribute") {
                if let Some(attr) = parse_attribute(line) { vo.attributes.push(attr); }
            } else if is_shorthand_line(line) && !line.starts_with("reference_to(") {
                if let Some(attr) = parse_shorthand_attribute(line) { vo.attributes.push(attr); }
            }
        }
        i += 1;
    }
    (vo, i + 1)
}

