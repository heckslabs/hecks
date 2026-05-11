
    if command == "dump-world" {
        let path = args.get(2).expect("usage: storehouse dump-world <file.world>");
        let source = std::fs::read_to_string(path).expect("cannot read");
        let world = storehouse::world_parser::parse(&source);
        println!("{}", serde_json::to_string_pretty(&dump_world_json(&world)).unwrap());
        return;
    }
