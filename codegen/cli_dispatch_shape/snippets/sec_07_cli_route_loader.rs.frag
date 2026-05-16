
/// Resolve the SubcommandRegistry heki path.
///
/// Uses the same resolution strategy as `find_subcommand_heki` but
/// targets `information/subcommand_registry/subcommand.heki` — the
/// canonical path written by the storehouse domain runtime (domain
/// SubcommandRegistry, aggregate Subcommand).
fn find_subcommand_registry_heki() -> Option<String> {
    let agg_dir = resolve_aggregates_dir()?;
    let p = std::path::Path::new(&agg_dir)
        .parent()?
        .join("information/subcommand_registry/subcommand.heki");
    if p.exists() { Some(p.to_string_lossy().into_owned()) } else { None }
}

/// Load all SubcommandRegistry rows into a name-keyed map.
///
/// Returns an empty map when the heki file is absent (graceful
/// degradation : missing catalog falls through to the legacy if-chain).
fn load_cli_routes() -> heki::Store {
    find_subcommand_registry_heki()
        .and_then(|path| heki::read(&path).ok())
        .unwrap_or_default()
}

/// Dispatch a CLI route from the SubcommandRegistry.
///
/// Returns `true` when the route was fully handled (caller should
/// `return`) ; `false` when the route falls through to the legacy
/// if-chain. The dispatch_address field is passed verbatim to
/// dispatch_hecksagon — never truncated — eliminating the i630 class
/// of bugs for every routed subcommand.
fn invoke_route(route: &heki::Record, args: &[String]) -> bool {
    // Non-empty dispatch_address with '::' → single-shot FQN dispatch.
    // The DispatchAddress invariant guarantees that any non-empty value
    // contains '::' ; we check anyway to be safe at the call site.
    let dispatch_address = route
        .get("dispatch_address")
        .and_then(|v| v.as_str())
        .unwrap_or("");
    if !dispatch_address.is_empty() && dispatch_address.contains("::") {
        let conception = storehouse_conception_root();
        let agg_dir = format!("{}/aggregates", conception);
        let attrs: std::collections::HashMap<String, serde_json::Value> = args[2..].iter()
            .filter_map(|a| {
                let mut parts = a.splitn(2, '=');
                let key = parts.next()?;
                let val = parts.next()?;
                Some((key.to_string(), serde_json::Value::String(val.to_string())))
            })
            .collect();
        dispatch_hecksagon(&agg_dir, dispatch_address, attrs);
        return true;
    }

    let handler = route.get("handler").and_then(|v| v.as_str()).unwrap_or("");
    match handler {
        "print_usage"    => { print_usage(); true }
        "run_loop"       => { run_loop(args); true }
        "run_pm_loop"    => { run_pm_loop(args); true }
        "run_daemon"     => { run_daemon(args); true }
        "run_macrophage" => { run_macrophage(args); true }
        "run_statusline" => { storehouse::run_statusline::run(); true }
        "run_clock"      => { run_clock(args); true }
        // Verbatim / unrecognised handler : fall through to the legacy
        // if-chain. Returns false so the caller continues.
        _                => false,
    }
}
