
    if command == "dump-hecksagon" {
        let path = args.get(2).expect("usage: storehouse dump-hecksagon <file.hecksagon>");
        let source = std::fs::read_to_string(path).expect("cannot read");
        let hex = storehouse::hecksagon_parser::parse(&source);
        println!("{}", serde_json::to_string_pretty(&dump_hecksagon_json(&hex)).unwrap());
        return;
    }
