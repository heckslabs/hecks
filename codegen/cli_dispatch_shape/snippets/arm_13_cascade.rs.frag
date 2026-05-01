
    if command == "cascade" {
        let path = args.get(2).expect("usage: hecks-life cascade <bluebook>");
        let source = std::fs::read_to_string(path).expect("cannot read");
        let domain = hecks_life::parser::parse(&source);
        for agg in &domain.aggregates {
            for cmd in &agg.commands {
                let events = hecks_life::cascade::cascade_emits(&domain, &cmd.name);
                if events.is_empty() { continue; }
                println!("{}.{} → {}", agg.name, cmd.name, events.join(" → "));
            }
        }
        return;
    }
