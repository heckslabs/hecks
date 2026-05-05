fn parse_aggregate(lines: &[&str]) -> (Aggregate, usize) {
    let first = lines[0].trim();
    let name = extract_string(first).unwrap_or_default();
    let desc = extract_second_string(first);

    let mut agg = Aggregate {
        name, description: desc,
        context: None, // populated by parse() after parse_aggregate returns
        attributes: vec![],
        commands: vec![], queries: vec![], value_objects: vec![],
        entities: vec![],
        references: vec![], lifecycle: None, identified_by: None,
        views: vec![],
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
                agg.commands.push(cmd);
                i += consumed;
                continue;
            } else if line.starts_with("value_object") {
                let (vo, consumed) = parse_value_object(&lines[i..]);
                agg.value_objects.push(vo);
                i += consumed;
                continue;
            } else if line.starts_with("entity") {
                let (ent, consumed) = parse_entity(&lines[i..]);
                agg.entities.push(ent);
                i += consumed;
                continue;
            } else if line.starts_with("attribute") {
                if let Some(attr) = parse_attribute(line) { agg.attributes.push(attr); }
                if ends_with_do_block(line) {
                    // `attribute :status, String, default: "X" do
                    //    transition "Cmd" => "next"
                    //  end`
                    // is sugar for a lifecycle keyed on that attribute.
                    // parse_lifecycle's first-line scan reads the symbol
                    // and `default:` kwarg the same way for both forms,
                    // so we can reuse it directly.
                    let (lc, consumed) = parse_lifecycle(&lines[i..]);
                    if !lc.transitions.is_empty() {
                        agg.lifecycle = Some(lc);
                    }
                    i += consumed;
                    continue;
                }
            } else if line.starts_with("description") {
                agg.description = extract_string(line);
            } else if line.starts_with("reference_to") {
                absorb_reference_to(line, &mut agg);
            } else if line.starts_with("lifecycle") {
                let (lc, consumed) = parse_lifecycle(&lines[i..]);
                agg.lifecycle = Some(lc);
                i += consumed;
                continue;
            } else if line.starts_with("identified_by") {
                agg.identified_by = extract_symbol(line);
            } else if line.starts_with("view") && ends_with_do_block(line) {
                // i254 — `view "for_customer" do show :a, :b end` declares
                // a named projection. parse_view returns the View IR + the
                // line count consumed (block-form only ; no inline form).
                let (v, consumed) = parse_view(&lines[i..]);
                agg.views.push(v);
                i += consumed;
                continue;
            } else if is_shorthand_line(line) {
                absorb_shorthand(line, &mut agg);
            } else if line.starts_with("query") {
                // i101 — block-form queries flow through parse_query
                // so attribute / where / order_by / limit clauses are
                // captured as structured IR. Single-line form keeps
                // the legacy push_query path for back-compat with
                // bluebooks that only declare name + description.
                if ends_with_do_block(line) {
                    let (q, consumed) = parse_query(&lines[i..]);
                    agg.queries.push(q);
                    i += consumed;
                    continue;
                }
                push_query(line, &mut agg, &mut depth);
            } else if ends_with_do_block(line) {
                depth += 1;
            }
        } else if ends_with_do_block(line) {
            depth += 1;
        }

        i += 1;
    }

    (agg, i + 1)
}

