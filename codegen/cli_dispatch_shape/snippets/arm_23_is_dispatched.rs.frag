
    // `storehouse is-dispatched <path>` — IR-query subcommand
    // (i122). Exit 0 + stdout line "<kind> in <source>" if the file
    // is claimed by some adapter / specializer ; exit 1 silently if
    // not. The LoC ratchet calls this per-file so growth in IR-
    // claimed surfaces stops counting against the non-bluebook
    // budget. Same substrate the antibody macrophage uses.
    if command == "is-dispatched" {
        let path = match args.get(2) {
            Some(p) => p.clone(),
            None => {
                eprintln!("usage: storehouse is-dispatched <path>");
                std::process::exit(2);
            }
        };
        match dispatch_lookup(&path) {
            Some(info) => {
                println!("{} in {}", info.kind, info.source);
                std::process::exit(0);
            }
            None => std::process::exit(1),
        }
    }
