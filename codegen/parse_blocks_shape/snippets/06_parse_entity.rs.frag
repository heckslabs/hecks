/// Parse a non-root entity block — DDD entity owned by its parent
/// aggregate. Entities have identity within the parent boundary and
/// can mutate (unlike value_objects which are immutable and replaced
/// wholesale). Distinct from a top-level aggregate : reachable only
/// through the parent root, lifecycle bounded by the parent.
///
/// i111-J — entity blocks now accept `command`, `query`, and
/// `lifecycle` declarations the same way aggregates do. The runtime
/// dispatches them as `Aggregate.Entity.Command` (3-part) or
/// `Aggregate.Command` when the bare name is unique among the
/// parent's entities. This closes the DDD-depth gap : authors who
/// collapse an aggregate into an entity no longer have to flatten
/// behaviors `on:` clauses to the parent root.
pub fn parse_entity(lines: &[&str]) -> (Entity, usize) {
    let first = lines[0].trim();
    let name = extract_string(first).unwrap_or_default();
    let mut ent = Entity {
        name,
        description: None,
        attributes: vec![],
        commands: vec![],
        queries: vec![],
        lifecycle: None,
        identified_by: None,
    };

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
            if line.starts_with("command") || is_shorthand_command(line) {
                let (cmd, consumed) = parse_command(&lines[i..]);
                ent.commands.push(cmd);
                i += consumed;
                continue;
            } else if line.starts_with("query") {
                // i101 — block-form queries delegate to parse_query so
                // entity-scoped queries get the same structured IR as
                // aggregate-scoped ones.
                if ends_with_do_block(line) {
                    let (q, consumed) = parse_query(&lines[i..]);
                    ent.queries.push(q);
                    i += consumed;
                    continue;
                }
                let q_name = extract_string(line).unwrap_or_else(|| {
                    line.split_whitespace().nth(1).unwrap_or("").trim_matches('"').to_string()
                });
                let q_desc = extract_second_string(line);
                ent.queries.push(Query {
                    name: q_name,
                    description: q_desc,
                    attributes: vec![],
                    wheres: vec![],
                    order_by: None,
                    limit: None,
                });
            } else if line.starts_with("lifecycle") {
                let (lc, consumed) = parse_lifecycle(&lines[i..]);
                ent.lifecycle = Some(lc);
                i += consumed;
                continue;
            } else if line.starts_with("identified_by") {
                ent.identified_by = extract_symbol(line);
            } else if line.starts_with("description") {
                ent.description = extract_string(line);
            } else if line.starts_with("attribute") {
                if let Some(attr) = parse_attribute(line) { ent.attributes.push(attr); }
                if ends_with_do_block(line) {
                    // attribute-with-lifecycle sugar (same shape as on
                    // aggregate) — parse_lifecycle reads symbol + default
                    // off the same first line.
                    let (lc, consumed) = parse_lifecycle(&lines[i..]);
                    if !lc.transitions.is_empty() { ent.lifecycle = Some(lc); }
                    i += consumed;
                    continue;
                }
            } else if is_shorthand_line(line) && !line.starts_with("reference_to(") {
                if let Some(attr) = parse_shorthand_attribute(line) { ent.attributes.push(attr); }
            } else if ends_with_do_block(line) {
                depth += 1;
            }
        } else if ends_with_do_block(line) {
            depth += 1;
        }

        i += 1;
    }
    (ent, i + 1)
}

