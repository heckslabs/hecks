
    if command == "cascade" {
        let path = args.get(2).expect("usage: storehouse cascade <bluebook>");
        let source = std::fs::read_to_string(path).expect("cannot read");
        let domain = storehouse::parser::parse(&source);
        for agg in &domain.aggregates {
            for cmd in &agg.commands {
                let events = storehouse::cascade::cascade_emits(&domain, &cmd.name);
                if events.is_empty() { continue; }
                println!("{}.{} → {}", agg.name, cmd.name, events.join(" → "));
            }
        }
        return;
    }
