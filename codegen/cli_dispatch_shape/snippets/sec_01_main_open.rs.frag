
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

    // SubcommandRegistry gate (i80 Unit C — routing through domain).
    // load_cli_routes() reads information/subcommand_registry/subcommand.heki
    // (the SubcommandRegistry domain's heki store). The record carries
    // handler, deprecated, and dispatch_address. invoke_route dispatches
    // recognised handlers (loop, pm_loop, daemon, macrophage, statusline,
    // clock, single-shot FQN) and returns true ; unrecognised handlers
    // return false and fall through to the legacy if-chain unchanged.
    // Graceful degradation : missing heki yields an empty map so the
    // if-chain continues to function as before.
    let routes = load_cli_routes();
    if let Some(route) = routes.get(command) {
        if route.get("deprecated").and_then(|v| v.as_str()) == Some("yes") {
            eprintln!("warning: subcommand '{}' is deprecated", command);
        }
        if invoke_route(route, &args) {
            return;
        }
    }
