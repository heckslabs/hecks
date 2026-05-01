
    // `hecks-life repl <file.bluebook>` — interactive REPL. Same shape
    // as the pre-PR `run` command so any script that relied on that
    // behavior moves to `repl`.
    if command == "repl" {
        let repl_path = args.get(2).unwrap_or_else(|| {
            eprintln!("Usage: hecks-life repl <file.bluebook>");
            std::process::exit(1);
        });
        let source = fs::read_to_string(repl_path).unwrap_or_else(|e| {
            eprintln!("Cannot read {}: {}", repl_path, e); std::process::exit(1);
        });
        let domain = parser::parse(&source);
        let seed_path = args.iter().position(|a| a == "--seed")
            .and_then(|i| args.get(i + 1))
            .map(|s| s.as_str());
        let mut rt = Runtime::boot(domain);
        load_seeds(&mut rt, seed_path);
        rt.run_interactive();
        return;
    }
