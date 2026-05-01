
fn main() {
    let args: Vec<String> = env::args().collect();

    // Detect being name from argv[0]: "miette" -> "Miette", "summer" -> "Summer"
    let being = being_from_argv0(&args[0]);

    // Named beings (miette/summer) with no subcommand go straight to terminal
    let is_named = std::path::Path::new(&args[0]).file_name()
        .map_or(false, |n| n == "miette" || n == "summer");

    if args.len() < 2 {
        if is_named {
            let dir = resolve_home(&being);
            run_terminal(&dir, &being);
            return;
        }
        print_usage();
        std::process::exit(1);
    }

    // Backwards compat: if arg[1] is a file path, treat as parse
    let (command, path) = if args.len() == 2 && args[1].contains('.') {
        ("parse", args[1].as_str())
    } else if args.len() >= 3 {
        (args[1].as_str(), args[2].as_str())
    } else {
        (args[1].as_str(), "")
    };

    // Subcommand catalog gate (i80 follow-up — multi-domain CLI split).
    // The Subcommand catalog (information/subcommand.heki) is the source
    // of truth for "what subcommands exist." Today this gate :
    //   1. honours a `deprecated: yes` flag with a stderr warning
    //   2. dispatches handlers that have been migrated to catalog-
    //      driven form (the match arm below) — currently only
    //      print_usage, with the rest falling through to the legacy
    //      if-chain unchanged
    //
    // Each future migration adds one more arm to the match below and
    // removes the corresponding branch from the if-chain. Once every
    // arm is here AND a capability runner implements it, the if-chain
    // retires entirely.
    if let Some(record) = lookup_subcommand(command) {
        if record.get("deprecated").and_then(|v| v.as_str()) == Some("yes") {
            eprintln!("warning: subcommand '{}' is deprecated", command);
        }
        let handler = record.get("handler").and_then(|v| v.as_str()).unwrap_or("");
        match handler {
            "print_usage" => { print_usage(); return; }
            // Future migrations land here ; the legacy if-chain
            // implements anything that hasn't moved yet.
            _ => {}
        }
    }
