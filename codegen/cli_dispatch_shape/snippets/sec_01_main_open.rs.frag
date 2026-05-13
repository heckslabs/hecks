
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

    // Cross-repo Tools.* dispatch (i518 follow-up). When invoked as
    // `storehouse Aggregate.Command [key=val ...]` from any cwd, route
    // straight into the default conception's aggregates dir. The check :
    //   * args[1] looks like `<PascalCase>.<PascalCase>` (the
    //     `Aggregate.Command` shape any dispatch would take)
    //   * args[1] is NOT a path that exists on disk (so an existing
    //     "parse this file" usage still wins)
    //   * not a recognised subcommand (`storehouse`, `lexicon`, ...)
    //     — those are handled by the regular if-chain below
    // Conception dir comes from HECKS_CONCEPTION_DIR or the canonical
    // ~/Projects/hecks/hecks_conception fallback (see
    // storehouse_conception_root). Explicit positional invocations
    // (`storehouse /path/to/conception Tools.Bash ...`) still work
    // because they fall through to the directory-or-bluebook dispatch
    // path further down. Backward-compatible.
    if args.len() >= 2 && looks_like_aggregate_command(&args[1])
        && !std::path::Path::new(&args[1]).exists()
    {
        let conception = storehouse_conception_root();
        let agg_dir = format!("{}/aggregates", conception);
        if std::path::Path::new(&agg_dir).is_dir() {
            let cmd_name = args[1].clone();
            let attrs: std::collections::HashMap<String, serde_json::Value> = args[2..].iter()
                .filter_map(|a| {
                    let mut parts = a.splitn(2, '=');
                    let key = parts.next()?;
                    let val = parts.next()?;
                    Some((key.to_string(), serde_json::Value::String(val.to_string())))
                })
                .collect();
            dispatch_hecksagon(&agg_dir, &cmd_name, attrs);
            return;
        }
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
