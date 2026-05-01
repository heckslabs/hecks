
    // Lexicon is now a hecksagon query
    if command == "lexicon" {
        let dir = if !path.is_empty() { path.to_string() } else { resolve_home(&being) };
        let query = args.get(3).map(|s| s.as_str());
        let agg_dir = format!("{}/aggregates", dir);
        if let Some(input) = query {
            let mut attrs = std::collections::HashMap::new();
            attrs.insert("input".into(), serde_json::json!(input));
            dispatch_hecksagon(&agg_dir, "MatchInput", attrs);
        } else {
            let attrs = std::collections::HashMap::new();
            dispatch_hecksagon(&agg_dir, "ListAll", attrs);
        }
        return;
    }
