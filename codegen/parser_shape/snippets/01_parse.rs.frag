pub fn parse(source: &str) -> Domain {
    let mut domain = Domain {
        name: String::new(),
        category: None,
        vision: None,
        aggregates: vec![],
        policies: vec![],
        fixtures: vec![],
        entrypoint: None,
        sections: vec![],
        process_managers: vec![],
    };

    let source = strip_shebang(source);

    let lines: Vec<&str> = source.lines().collect();
    let mut i = 0;

    while i < lines.len() {
        let line = lines[i].trim();

        if line.starts_with("Hecks.bluebook") {
            if let Some(name) = extract_string(line) {
                domain.name = name;
            }
        }

        if line.starts_with("category") && !line.starts_with("category,") {
            if let Some(cat) = extract_string(line) {
                domain.category = Some(cat);
            }
        }

        if line.starts_with("vision") {
            if let Some(v) = extract_string(line) {
                domain.vision = Some(v);
            }
        }

        if line.starts_with("entrypoint") {
            if let Some(ep) = extract_string(line) {
                domain.entrypoint = Some(ep);
            }
        }

        if line.starts_with("aggregate") {
            let (mut agg, consumed) = parse_aggregate(&lines[i..]);
            // i142 — bluebooks ARE bounded contexts. Stamp the
            // bluebook's namespace name onto every aggregate it
            // declares, so dispatch can resolve Context.Aggregate.Command
            // and same-name aggregates across contexts don't collide.
            if !domain.name.is_empty() {
                agg.context = Some(domain.name.clone());
            }
            domain.aggregates.push(agg);
            i += consumed;
            continue;
        }

        if line.starts_with("section ") || line.starts_with("section\t") {
            let (sec, consumed) = parse_section(&lines[i..]);
            domain.sections.push(sec);
            i += consumed;
            continue;
        }

        if line.starts_with("policy") {
            let (policy, consumed) = parse_policy(&lines[i..]);
            domain.policies.push(policy);
            i += consumed;
            continue;
        }

        if line.starts_with("process_manager") {
            let (pm, consumed) = parse_process_manager(&lines[i..]);
            domain.process_managers.push(pm);
            i += consumed;
            continue;
        }

        if line.starts_with("fixture") {
            if ends_with_do_block(line) {
                let mut depth = 1;
                while i + 1 < lines.len() && depth > 0 {
                    i += 1;
                    let l = lines[i].trim();
                    if l == "end" { depth -= 1; }
                    else if ends_with_do_block(l) { depth += 1; }
                }
            }
        }

        i += 1;
    }

    domain
}

