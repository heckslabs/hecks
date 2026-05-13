
    // Batch mode: read file paths from stdin, process each
    if path == "--batch" {
        run_batch(command);
        return;
    }

    // Bluebook dispatch: storehouse <dir-or-file> <Domain::Aggregate.Command>
    // e.g. storehouse aggregates/ Tools::Tools.Bash shell_command="echo hi"
    //
    // i560 v2 (2026-05-12) — the CLI surface accepts ONLY the
    // canonical fully-qualified form `Domain::Aggregate.Command`
    // (commands, PascalCase) or `Domain::Aggregate.query_name`
    // (queries, snake_case). The legacy short forms
    // (`Aggregate.Command`, `Context.Aggregate.Command`, bare
    // `Command`) are rejected here with a helpful message naming
    // the new form. Internal cascade dispatch through
    // `Runtime::drain_policies` bypasses this gate and still
    // resolves the short forms via command_dispatch::resolve, so
    // bluebook `trigger_command` declarations keep working.
    if !path.is_empty()
        && path.contains('.')
        && path.chars().next().map_or(false, |c| c.is_uppercase())
        && (std::path::Path::new(command).is_dir()
            || command.ends_with(".bluebook"))
    {
        let target = command;
        let cmd_name = path;

        // i560 v2 — strict FQN gate. The canonical form has `::` as
        // the domain/aggregate separator AND `.` as the
        // aggregate/command separator. Anything missing the `::` is
        // a short-form invocation : reject with the new format name.
        if !cmd_name.contains("::") {
            eprintln!(
                "dispatch error: '{}' is a short-form address. The CLI now requires the fully-qualified form Domain::Aggregate.Command (commands, PascalCase) or Domain::Aggregate.query_name (queries, snake_case). Example: 'Tools::Tools.Bash', 'Discipline::Macrophage.Run'.",
                cmd_name
            );
            std::process::exit(1);
        }
        // Parse key=value attrs from remaining args
        let attrs: std::collections::HashMap<String, serde_json::Value> = args[3..].iter()
            .filter_map(|a| {
                let mut parts = a.splitn(2, '=');
                let key = parts.next()?;
                let val = parts.next()?;
                Some((key.to_string(), serde_json::Value::String(val.to_string())))
            })
            .collect();
        if std::path::Path::new(target).is_dir() {
            dispatch_hecksagon(target, cmd_name, attrs);
        } else {
            let source = fs::read_to_string(target).unwrap_or_else(|e| {
                eprintln!("Cannot read {}: {}", target, e);
                std::process::exit(1);
            });
            let domain = parser::parse(&source);
            let data_dir = find_world_heki_dir(target)
                .unwrap_or_else(|| format!("{}/data", std::path::Path::new(target).parent()
                    .unwrap_or(std::path::Path::new(".")).display()));
            let mut rt = Runtime::boot_with_data_dir(domain, Some(data_dir));
            match rt.dispatch(cmd_name, std::collections::HashMap::new()) {
                Ok(result) => println!("{}", serde_json::json!({
                    "ok": true, "aggregate": result.aggregate_type, "id": result.aggregate_id,
                })),
                Err(e) => { eprintln!("dispatch error: {:?}", e); std::process::exit(1); }
            }
        }
        return;
    }

    if path.is_empty() {
        eprintln!("Usage: storehouse {} <bluebook-file-or-dir>", command);
        std::process::exit(1);
    }

    // Multi-domain serve
    if command == "serve" && std::path::Path::new(path).is_dir() {
        let port: u16 = args.iter().find(|a| a.parse::<u16>().is_ok())
            .and_then(|s| s.parse().ok()).unwrap_or(3100);
        server::multi::serve_directory(path, port);
        return;
    }

    let source = fs::read_to_string(path).unwrap_or_else(|e| {
        eprintln!("Cannot read {}: {}", path, e);
        std::process::exit(1);
    });

    // Dispatch behaviors files (`Hecks.behaviors "..." do ... end`) to the
    // separate parser/dump path. Only commands that make sense for a test
    // suite are handled here — others fall through to the domain path
    // (which would mis-parse the source).
    if behaviors_parser::is_behaviors_source(&source) {
        let suite = behaviors_parser::parse(&source);
        match command {
            "dump" => {
                println!("{}", serde_json::to_string_pretty(&behaviors_dump::dump(&suite)).unwrap());
                return;
            }
            "parse" | "inspect" | "tree" | "list" => {
                println!("TestSuite \"{}\" — {} test(s)", suite.name, suite.tests.len());
                for t in &suite.tests {
                    println!("  • {}", t.description);
                }
                return;
            }
            _ => {
                eprintln!("command `{}` not supported for behaviors files", command);
                std::process::exit(1);
            }
        }
    }

    let domain = parser::parse(&source);

    let seed_path = args.iter().position(|a| a == "--seed")
        .and_then(|i| args.get(i + 1))
        .map(|s| s.as_str());

    match command {
        "parse" => { println!("{}", domain); emit_validator_warnings_to_stderr(&domain); }
        "dump" => { println!("{}", serde_json::to_string_pretty(&dump::dump(&domain)).unwrap()); emit_validator_warnings_to_stderr(&domain); }
        "validate" => {
            emit_validator_warnings_to_stderr(&domain);
            // --corpus <dir> opts into corpus-wide checks : merges every
            // bluebook under <dir> via load_combined_domain, then runs
            // the corpus-only rules (phantom-trigger INVALID + dangling-
            // event WARNING). Without --corpus, the per-file checks alone
            // run and the corpus-only rules stay silent (they would
            // false-positive on cross-bluebook flow).
            let corpus_dir = args.iter().position(|a| a == "--corpus")
                .and_then(|i| args.get(i + 1))
                .map(|s| s.as_str());
            let mut errors = validator::validate(&domain);
            if let Some(dir) = corpus_dir {
                let corpus = load_combined_domain(dir);
                // Corpus-wide rules live in validator_corpus (not in
                // validator.rs / validator_warnings.rs) so those two
                // files keep byte-identity with their specializers.
                errors.extend(storehouse::validator_corpus::corpus_phantom_trigger_errors(&corpus));
                for w in storehouse::validator_corpus::policy_event_warnings(&corpus) {
                    eprintln!("{}", w);
                }
                for w in storehouse::validator_corpus::bare_name_collisions(&corpus) {
                    eprintln!("{}", w);
                }
            }
            if errors.is_empty() {
                println!("VALID — {} ({} aggregates)", domain.name, domain.aggregates.len());
            } else {
                println!("INVALID — {} errors:", errors.len());
                for err in &errors { println!("  {}", err); }
                std::process::exit(1);
            }
        }
        "inspect" | "tree" | "list" => { println!("{}", domain); emit_validator_warnings_to_stderr(&domain); }
        "train" => {
            let vision = domain.vision.as_deref().unwrap_or(&domain.name);
            let source_esc = fs::read_to_string(path).unwrap_or_default()
                .replace('\\', "\\\\").replace('"', "\\\"").replace('\n', "\\n");
            println!(r#"{{"prompt":"Conceive a domain for: {}","completion":"{}","domain":"{}","aggregates":{},"commands":{},"policies":{}}}"#,
                vision.replace('"', "\\\""), source_esc, domain.name,
                domain.aggregates.len(),
                domain.aggregates.iter().map(|a| a.commands.len()).sum::<usize>(),
                domain.policies.len());
        }
        "project" => eprintln!("project is now: storehouse serve <dir-or-file>"),
        "counts" => {
            let cmds: usize = domain.aggregates.iter().map(|a| a.commands.len()).sum();
            println!("{}|{}|{}|{}|{}", domain.name, domain.aggregates.len(), cmds, domain.policies.len(), domain.fixtures.len());
        }
        "serve" => {
            let port: u16 = args.iter().find(|a| a.parse::<u16>().is_ok())
                .and_then(|s| s.parse().ok()).unwrap_or(3100);
            let mut rt = Runtime::boot(domain);
            load_seeds(&mut rt, seed_path);
            server::serve(rt, port);
        }
        _ => {
            eprintln!("Unknown command: {}", command);
            print_usage();
            std::process::exit(1);
        }
    }
}
