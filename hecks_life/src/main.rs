//! Hecks Life — the Bluebook compiler and runtime
//!
//! Reads .bluebook files, parses them into IR, and executes them.
//! The Bluebook is DNA. This is the ribosome. The runtime is life.
//!
//! [antibody-exempt: hecks_life/src/main.rs — wires the :llm hecksagon
//!  adapter into dispatch_hecksagon. This IS the structural rewrite
//!  that lets wake_review and interpret_dream fire end-to-end via
//!  bluebook. Same i80 retirement contract ; closes the i109 :llm
//!  runtime gap that PR #455 explicitly named. Rewriting IS the work.]
//!
//! Usage:
//!   hecks-life parse     pizzas.bluebook
//!   hecks-life validate  pizzas.bluebook
//!   hecks-life inspect   pizzas.bluebook
//!   hecks-life tree      pizzas.bluebook
//!   hecks-life list      pizzas.bluebook
//!   hecks-life run       pizzas.bluebook [--seed seeds.txt]
//!   hecks-life serve     pizzas.bluebook [--seed seeds.txt] [port]
//!   hecks-life serve     path/to/hecks/ [port]
//!   hecks-life conceive  "Name" "vision" --corpus dir1 dir2
//!   hecks-life develop   target.bluebook --add "feature"
//!
//! [antibody-exempt: hecks_life/src/main.rs — wires validator_warnings into
//!  dispatch arms. This IS the structural rewrite that closes the gap
//!  between the bluebook-declared rules (capabilities/validator_warnings_shape/)
//!  and runtime enforcement. Same i80 retirement contract as run_loop /
//!  run_daemon / run_enforce_edit. Net ~12 LoC.]

use hecks_life::{parser, validator, validator_warnings, server, conceiver, heki, heki_query, dump,
                 behaviors_parser, behaviors_dump};
use hecks_life::runtime::Runtime;

use std::env;
use std::fs;

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

    if command == "help" || command == "--help" {
        print_usage();
        return;
    }

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

    if command == "terminal" {
        let dir = if !path.is_empty() {
            path.to_string()
        } else {
            resolve_home(&being)
        };
        run_terminal(&dir, &being);
        return;
    }

    // These commands now dispatch through the hecksagon:
    //   speak → Speech.Speak, status → Heartbeat.ReadVitals,
    //   boot → Identity.Identify
    // (`daemon` was on this list when it meant "start mindstream.sh" ;
    // it now names the process-lifecycle primitive and dispatches via
    // run_daemon below.)
    if command == "speak" || command == "status" || command == "musings"
        || command == "boot" {
        eprintln!("'{}' now dispatches through the hecksagon:", command);
        eprintln!("  hecks-life aggregates/ Aggregate.Command");
        return;
    }

    if command == "heki" {
        run_heki(&args);
        return;
    }

    if command == "conceive" {
        conceiver::commands::run_conceive(&args);
        return;
    }

    if command == "develop" {
        conceiver::commands::run_develop(&args);
        return;
    }

    if command == "conceive-behaviors" {
        hecks_life::behaviors_conceiver::commands::run_conceive_behaviors(&args);
        return;
    }

    if command == "behaviors" {
        run_behaviors(&args);
        return;
    }

    if command == "dump-fixtures" {
        let path = args.get(2).expect("usage: hecks-life dump-fixtures <file.fixtures>");
        let source = std::fs::read_to_string(path).expect("cannot read");
        let file = hecks_life::fixtures_parser::parse(&source);
        let mut payload = serde_json::json!({
            "domain": file.domain_name,
            "fixtures": file.fixtures.iter().map(|f| {
                let mut attrs = serde_json::Map::new();
                for (k, v) in &f.attributes {
                    attrs.insert(k.clone(), serde_json::Value::String(v.clone()));
                }
                serde_json::json!({
                    "aggregate": f.aggregate_name,
                    "name": f.name.clone().unwrap_or_default(),
                    "attrs": attrs,
                })
            }).collect::<Vec<_>>(),
        });
        // i42: emit a `catalogs` key only when the file actually
        // declares catalog schemas. Absent-key preserves the pre-i42
        // payload shape for the ~356 existing .fixtures files, so
        // downstream consumers that don't care about catalogs see
        // exactly the same JSON they saw before.
        if !file.catalogs.is_empty() {
            let mut catalogs = serde_json::Map::new();
            for (agg, attrs) in &file.catalogs {
                let rows: Vec<serde_json::Value> = attrs.iter().map(|a| {
                    serde_json::json!({ "name": a.name, "type": a.type_name })
                }).collect();
                catalogs.insert(agg.clone(), serde_json::Value::Array(rows));
            }
            payload.as_object_mut().unwrap()
                .insert("catalogs".into(), serde_json::Value::Object(catalogs));
        }
        println!("{}", serde_json::to_string_pretty(&payload).unwrap());
        return;
    }

    if command == "dump-world" {
        let path = args.get(2).expect("usage: hecks-life dump-world <file.world>");
        let source = std::fs::read_to_string(path).expect("cannot read");
        let world = hecks_life::world_parser::parse(&source);
        println!("{}", serde_json::to_string_pretty(&dump_world_json(&world)).unwrap());
        return;
    }

    if command == "dump-hecksagon" {
        let path = args.get(2).expect("usage: hecks-life dump-hecksagon <file.hecksagon>");
        let source = std::fs::read_to_string(path).expect("cannot read");
        let hex = hecks_life::hecksagon_parser::parse(&source);
        println!("{}", serde_json::to_string_pretty(&dump_hecksagon_json(&hex)).unwrap());
        return;
    }

    if command == "specialize" {
        run_specialize(&args);
        return;
    }

    if command == "cascade" {
        let path = args.get(2).expect("usage: hecks-life cascade <bluebook>");
        let source = std::fs::read_to_string(path).expect("cannot read");
        let domain = hecks_life::parser::parse(&source);
        for agg in &domain.aggregates {
            for cmd in &agg.commands {
                let events = hecks_life::cascade::cascade_emits(&domain, &cmd.name);
                if events.is_empty() { continue; }
                println!("{}.{} → {}", agg.name, cmd.name, events.join(" → "));
            }
        }
        return;
    }

    if command == "check-io" {
        run_check_io(&args);
        return;
    }

    if command == "check-lifecycle" {
        run_check_lifecycle(&args);
        return;
    }

    if command == "check-duplicate-policies" {
        run_check_duplicate_policies(&args);
        return;
    }

    if command == "check-all" {
        run_check_all(&args);
        return;
    }

    // `hecks-life run <file.bluebook> [key=val ...]`
    //
    // Script-mode execution: strip shebang, parse .bluebook + companion
    // .hecksagon, wire adapters, dispatch `entrypoint` with argv-bound
    // attrs. Exits 0/1/2/3/4 per hecks_life::run::ExitKind.
    //
    // The legacy interactive REPL that used to live under `run` now
    // lives under `hecks-life repl <file>` (below).
    if command == "run" {
        std::process::exit(hecks_life::run::run_script(&args));
    }

    // `hecks-life loop <agg-dir-or-bluebook> <Aggregate.Command> --every <duration> [key=val ...]`
    //
    // Cadence-loop primitive (i76). Boots the runtime once and dispatches
    // the named command at the given cadence in a tight loop, no shell
    // wrapper required. Replaces the `while true; do ...; sleep N; done`
    // pattern that body daemons (heart, breath, circadian, ultradian,
    // mindstream, sleep_cycle) currently use, where each iteration paid
    // a full runtime-boot cost.
    //
    // Duration accepts "1s", "500ms", "2m" — anything parsed by
    // parse_loop_duration. SIGINT / SIGTERM exits cleanly.
    //
    // [TRANSITIONAL] Like the speak/status/musings/boot/daemon wrappers
    // above, this hardcoded route is itself a bluebook smell — adding it
    // to main.rs is exactly what i80 (CLI routing as bluebook) names as
    // the wrong layer. Kept here only until i80's cli.bluebook lands and
    // every CLI subcommand becomes a declared route, at which point this
    // function retires alongside the others. See i80 for the retirement
    // contract.
    if command == "loop" {
        run_loop(&args);
        return;
    }

    // `hecks-life daemon <ensure|status|stop> <pidfile> [command...]`
    //
    // Process-lifecycle primitive — the runtime gap that kept boot_miette
    // in shell. `ensure <pidfile> <cmd> [args]` reads the pidfile, returns
    // alive if the PID is still running (idempotent boot), otherwise spawns
    // the command detached (setsid + null stdio) and writes the new PID.
    // No wrapping subshells, no PPID=1 orphan launchers — the leak that
    // accumulated five ghost shells over today's session is structurally
    // closed. Sibling of the cadence-loop primitive (`hecks-life loop`) ;
    // together they let bluebook capabilities declare daemon lifecycles
    // without reaching for shell. boot_miette.sh's `( cd "$DIR" && nohup
    // ./script & )` pattern retires once it migrates to this primitive.
    if command == "daemon" {
        run_daemon(&args);
        return;
    }

    // `hecks-life enforce-edit` — PostToolUse listener primitive.
    //
    // Reads tool-input JSON from stdin, classifies the touched file
    // by extension, dispatches Enforcer.RecordXxxEdit (and, for
    // imperative-language files, Enforcer.Complain), prints the
    // complaint to stderr, exits 2 so Claude Code routes the
    // complaint to the agent as a system reminder.
    //
    // Closes the runtime gap (i104) that previously forced
    // enforce_bluebook.sh to exist — Claude Code's PostToolUse hook
    // contract takes a command, and the command can now be hecks-life
    // directly. No shell glue. Same family as `hecks-life loop` and
    // `hecks-life daemon` — kernel-surface primitives a bluebook
    // capability dispatches into. The Enforcer brain stays in
    // aggregates/enforcer.bluebook.
    if command == "enforce-edit" {
        run_enforce_edit(&args);
        return;
    }

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

    // Batch mode: read file paths from stdin, process each
    if path == "--batch" {
        run_batch(command);
        return;
    }

    // Bluebook dispatch: hecks-life <dir-or-file> <CommandName>
    // If first arg is a directory/bluebook and second is a PascalCase command, dispatch it
    // Bluebook dispatch: hecks-life <dir-or-file> Aggregate.Command
    // e.g. hecks-life aggregates/ Heartbeat.Beat
    if !path.is_empty()
        && path.contains('.')
        && path.chars().next().map_or(false, |c| c.is_uppercase())
        && (std::path::Path::new(command).is_dir()
            || command.ends_with(".bluebook"))
    {
        let target = command;
        let cmd_name = path.split('.').last().unwrap_or(path);
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
        eprintln!("Usage: hecks-life {} <bluebook-file-or-dir>", command);
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
            let errors = validator::validate(&domain);
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
        "project" => eprintln!("project is now: hecks-life serve <dir-or-file>"),
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

fn run_batch(command: &str) {
    use std::io::{self, BufRead};
    let stdin = io::stdin();
    let (mut valid, mut invalid, mut total) = (0, 0, 0);

    for line in stdin.lock().lines() {
        let file_path = match line {
            Ok(l) => l.trim().to_string(),
            Err(_) => continue,
        };
        if file_path.is_empty() { continue; }
        total += 1;

        let source = match fs::read_to_string(&file_path) {
            Ok(s) => s,
            Err(e) => { eprintln!("ERROR|{}|{}", file_path, e); invalid += 1; continue; }
        };

        let domain = parser::parse(&source);
        match command {
            "validate" => {
                emit_validator_warnings_to_stderr(&domain);
                let errors = validator::validate(&domain);
                if errors.is_empty() {
                    println!("VALID|{}", file_path); valid += 1;
                }
                else { println!("INVALID|{}|{}", file_path, errors.join("; ")); invalid += 1; }
            }
            "counts" => {
                let cmds: usize = domain.aggregates.iter().map(|a| a.commands.len()).sum();
                println!("{}|{}|{}|{}|{}|{}", file_path, domain.name, domain.aggregates.len(), cmds, domain.policies.len(), domain.fixtures.len());
                valid += 1;
            }
            _ => { eprintln!("Batch mode only supports: validate, counts"); std::process::exit(1); }
        }
    }
    eprintln!("Batch: {} total, {} valid, {} invalid", total, valid, invalid);
    if invalid > 0 { std::process::exit(1); }
}

fn load_seeds(rt: &mut Runtime, seed_path: Option<&str>) {
    if let Some(path) = seed_path {
        match hecks_life::runtime::seed_loader::load(rt, path) {
            Ok(count) => eprintln!("  loaded {} seed commands from {}", count, path),
            Err(e) => eprintln!("  seed error: {}", e),
        }
    }
}

/// `hecks-life behaviors path/to/X_behavioral_tests.bluebook`
///
/// Loads the matching source bluebook (suffix-stripped: pizzas_behavioral_tests
/// → pizzas), runs every test through Runtime::boot in pure-memory mode,
/// prints PASS/FAIL per test plus a summary, exits non-zero on any failure.
///
/// Pure memory by construction — Runtime::boot has no data_dir, no
/// hecksagon, no adapters. If a test triggers IO, the source bluebook
/// is the thing to fix.
fn run_behaviors(args: &[String]) {
    let suite_path = args.get(2).unwrap_or_else(|| {
        eprintln!("Usage: hecks-life behaviors <X_behavioral_tests.bluebook>");
        std::process::exit(1);
    });
    let source_path = source_for_suite(suite_path);
    let suite_text = std::fs::read_to_string(suite_path).unwrap_or_else(|e| {
        eprintln!("Cannot read {}: {}", suite_path, e); std::process::exit(1);
    });
    let source_text = std::fs::read_to_string(&source_path).unwrap_or_else(|e| {
        eprintln!("Cannot read source {}: {}", source_path, e); std::process::exit(1);
    });
    if !hecks_life::behaviors_parser::is_behaviors_source(&suite_text) {
        eprintln!("{} is not a Hecks.behaviors file", suite_path);
        std::process::exit(1);
    }
    let suite = hecks_life::behaviors_parser::parse(&suite_text);

    // Auto-load sibling .fixtures if present (i4 gap 8). Cross-aggregate
    // cascades that read state seeded by another aggregate's fixtures no
    // longer need explicit setup chains in every test.
    let fixtures_path = hecks_life::behaviors_fixtures::locate_path(suite_path);
    let fixtures = fixtures_path.as_deref()
        .and_then(hecks_life::behaviors_fixtures::parse_file);

    println!("Running {} test(s) from {}", suite.tests.len(), suite_path);
    println!("  source: {}", source_path);
    if let Some(ref fp) = fixtures_path {
        println!("  fixtures: {}", fp);
    }
    println!();

    let result = hecks_life::behaviors_runner::run_suite_with_fixtures(
        &source_text, &suite, fixtures.as_ref(),
    );
    for run in &result.runs {
        let icon = match run.status {
            hecks_life::behaviors_runner::TestStatus::Pass  => "✓",
            hecks_life::behaviors_runner::TestStatus::Fail  => "✗",
            hecks_life::behaviors_runner::TestStatus::Error => "⚠",
        };
        println!("{} {}", icon, run.description);
        if let Some(msg) = &run.message {
            println!("    {}", msg);
        }
    }
    println!("\n{} passed, {} failed, {} errored",
             result.passed(), result.failed(), result.errored());
    if !result.all_passed() { std::process::exit(1); }
}

/// `hecks-life check-io <bluebook> [--strict]`
///
/// Asserts a bluebook is pure-memory-runnable. Two layers: static IR
/// scan for IO-suggestive patterns (advisory by default), and a
/// runtime smoke that boots Runtime::boot in pure-memory mode and
/// dispatches every command. Exit 0 when runtime smoke passes
/// (--strict promotes warnings to errors).
fn run_check_io(args: &[String]) {
    let path = args.get(2).unwrap_or_else(|| {
        eprintln!("Usage: hecks-life check-io <bluebook> [--strict]");
        std::process::exit(1);
    });
    let strict = args.iter().any(|a| a == "--strict");

    let source = std::fs::read_to_string(path).unwrap_or_else(|e| {
        eprintln!("Cannot read {}: {}", path, e); std::process::exit(1);
    });
    let domain = hecks_life::parser::parse(&source);
    if domain.aggregates.is_empty() {
        eprintln!("{} has no aggregates — nothing to validate", path);
        std::process::exit(1);
    }

    println!("Checking {} ({})", domain.name, path);

    let report = hecks_life::io_validator::check(domain);

    if !report.static_findings.is_empty() {
        println!("\nStatic IR scan:");
        for f in &report.static_findings {
            println!("  {} {} — {}", f.icon(), f.location, f.message);
        }
    } else {
        println!("\nStatic IR scan: clean");
    }

    if !report.runtime_findings.is_empty() {
        println!("\nRuntime smoke (pure-memory dispatch):");
        for f in &report.runtime_findings {
            println!("  {} {} — {}", f.icon(), f.location, f.message);
        }
    } else {
        println!("\nRuntime smoke: clean");
    }

    println!("\n{} error(s), {} warning(s)", report.errors(), report.warnings());
    if report.passes(strict) {
        println!("PASS — {} runs in pure memory", path);
    } else {
        println!("FAIL — {} {}", path,
                 if report.errors() > 0 { "has IO-implying issues" }
                 else { "has warnings (--strict)" });
        std::process::exit(1);
    }
}

/// `hecks-life check-lifecycle <bluebook> [--strict]`
///
/// Catches contradictory lifecycle declarations — transitions whose
/// `from:` state is unreachable, defaults that no transition can
/// exit, etc. Static IR walk; no runtime needed.
fn run_check_lifecycle(args: &[String]) {
    let path = args.get(2).unwrap_or_else(|| {
        eprintln!("Usage: hecks-life check-lifecycle <bluebook> [--strict]");
        std::process::exit(1);
    });
    let strict = args.iter().any(|a| a == "--strict");

    let source = std::fs::read_to_string(path).unwrap_or_else(|e| {
        eprintln!("Cannot read {}: {}", path, e); std::process::exit(1);
    });
    let domain = hecks_life::parser::parse(&source);
    if domain.aggregates.is_empty() {
        eprintln!("{} has no aggregates — nothing to check", path);
        std::process::exit(1);
    }

    println!("Checking {} ({})", domain.name, path);

    let report = hecks_life::lifecycle_validator::check(&domain);
    if report.findings.is_empty() {
        println!("\nLifecycle: clean");
    } else {
        println!("\nLifecycle:");
        for f in &report.findings {
            println!("  {} {} — {}", f.icon(), f.location, f.message);
        }
    }

    println!("\n{} error(s), {} warning(s)", report.errors(), report.warnings());
    if report.passes(strict) {
        println!("PASS — {} has consistent lifecycles", path);
    } else {
        println!("FAIL — {} {}", path,
                 if report.errors() > 0 { "has unreachable transitions" }
                 else { "has stuck-default warnings (--strict)" });
        std::process::exit(1);
    }
}

/// `hecks-life check-duplicate-policies <bluebook>`
///
/// Refuses bluebooks that declare two or more policies sharing the
/// same `(on_event, trigger_command)` pair. Today those silently
/// coexist — the runtime fires every matching policy, so the trigger
/// command runs once per duplicate. Flat IR walk; no runtime needed.
fn run_check_duplicate_policies(args: &[String]) {
    let path = args.get(2).unwrap_or_else(|| {
        eprintln!("Usage: hecks-life check-duplicate-policies <bluebook>");
        std::process::exit(1);
    });

    let source = std::fs::read_to_string(path).unwrap_or_else(|e| {
        eprintln!("Cannot read {}: {}", path, e); std::process::exit(1);
    });
    let domain = hecks_life::parser::parse(&source);

    println!("Checking {} ({})", domain.name, path);

    let report = hecks_life::duplicate_policy_validator::check(&domain);
    if report.findings.is_empty() {
        println!("\nPolicies: clean ({} policies, no duplicates)", domain.policies.len());
    } else {
        println!("\nDuplicate policies:");
        for f in &report.findings {
            println!("  {} {} — {}", f.icon(), f.location, f.message);
        }
    }

    println!("\n{} error(s)", report.errors());
    if report.passes() {
        println!("PASS — {} has no duplicate (event, trigger) pairs", path);
    } else {
        println!("FAIL — {} has duplicate policies", path);
        std::process::exit(1);
    }
}

/// `hecks-life check-all <bluebook> [--strict]`
///
/// Run every validator in one go: lifecycle (unreachable transitions
/// + givens + mutation refs) and IO (declarative IO smells + pure-
/// memory dispatch smoke). Exits 0 only if both pass.
fn run_check_all(args: &[String]) {
    let path = args.get(2).unwrap_or_else(|| {
        eprintln!("Usage: hecks-life check-all <bluebook> [--strict]");
        std::process::exit(1);
    });
    let strict = args.iter().any(|a| a == "--strict");

    let source = std::fs::read_to_string(path).unwrap_or_else(|e| {
        eprintln!("Cannot read {}: {}", path, e); std::process::exit(1);
    });
    let domain = hecks_life::parser::parse(&source);
    if domain.aggregates.is_empty() {
        eprintln!("{} has no aggregates — nothing to check", path);
        std::process::exit(1);
    }

    println!("Checking {} ({})", domain.name, path);
    let mut overall_ok = true;

    // Lifecycle (borrows the domain — runs first).
    let lc = hecks_life::lifecycle_validator::check(&domain);
    if !lc.findings.is_empty() {
        println!("\nLifecycle:");
        for f in &lc.findings {
            println!("  {} {} — {}", f.icon(), f.location, f.message);
        }
    } else {
        println!("\nLifecycle: clean");
    }
    if !lc.passes(strict) { overall_ok = false; }

    // IO (consumes the domain — runs second).
    let io = hecks_life::io_validator::check(domain);
    if !io.static_findings.is_empty() {
        println!("\nIO static scan:");
        for f in &io.static_findings {
            println!("  {} {} — {}", f.icon(), f.location, f.message);
        }
    } else {
        println!("\nIO static scan: clean");
    }
    if !io.runtime_findings.is_empty() {
        println!("\nIO runtime smoke:");
        for f in &io.runtime_findings {
            println!("  {} {} — {}", f.icon(), f.location, f.message);
        }
    } else {
        println!("\nIO runtime smoke: clean");
    }
    if !io.passes(strict) { overall_ok = false; }

    let total_errs = lc.errors() + io.errors();
    let total_warns = lc.warnings() + io.warnings();
    println!("\n{} error(s), {} warning(s)", total_errs, total_warns);
    if overall_ok {
        println!("PASS — {} is healthy{}", path, if strict { " (strict)" } else { "" });
    } else {
        println!("FAIL — {} has issues", path);
        std::process::exit(1);
    }
}

/// `hecks-life specialize <target> [--output PATH]`
///
/// i51 Phase D pilot — Rust-native specializer driver. Mirrors
/// `bin/specialize <target>` on the Ruby side; both runtimes must
/// produce byte-identical output for every ported target until the
/// migration completes.
///
/// Target name (the first positional arg) dispatches to the matching
/// module under `hecks_life::specializer::`. Writes to `--output
/// PATH` when provided, otherwise prints to stdout.
fn run_specialize(args: &[String]) {
    let target = args.get(2).map(|s| s.as_str()).unwrap_or("");
    if target.is_empty() {
        eprintln!("Usage: hecks-life specialize <target> [--output PATH]");
        std::process::exit(2);
    }

    let output_path: Option<String> = args
        .iter()
        .position(|a| a == "--output" || a == "-o")
        .and_then(|i| args.get(i + 1).cloned());

    let repo_root = match specialize_repo_root() {
        Ok(p) => p,
        Err(e) => {
            eprintln!("cannot locate repo root: {}", e);
            std::process::exit(1);
        }
    };

    let rust = match hecks_life::specializer::emit(target, &repo_root) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("specialize {} failed: {}", target, e);
            std::process::exit(1);
        }
    };

    match output_path {
        Some(p) => {
            if let Err(e) = std::fs::write(&p, &rust) {
                eprintln!("cannot write {}: {}", p, e);
                std::process::exit(1);
            }
            eprintln!("wrote {} bytes to {}", rust.len(), p);
        }
        None => print!("{}", rust),
    }
}

/// Locate the repository root for the `specialize` subcommand.
///
/// Uses `env::current_dir` — invocation convention is `hecks-life
/// specialize …` run from the repo root (same as `bin/specialize` on
/// the Ruby side). A sanity check verifies the expected
/// `hecks_conception/` sibling exists.
fn specialize_repo_root() -> Result<std::path::PathBuf, Box<dyn std::error::Error>> {
    let cwd = env::current_dir()?;
    if !cwd.join("hecks_conception").is_dir() {
        return Err(format!(
            "expected to run `specialize` from the repo root (cwd={}, no hecks_conception/ sibling)",
            cwd.display()
        )
        .into());
    }
    Ok(cwd)
}

/// Find the source bluebook for a behaviors file.
///
/// Two name conventions, in order of preference:
///   `path/to/foo.behaviors`                    → `path/to/foo.bluebook`
///   `path/to/foo_behavioral_tests.bluebook`    → `path/to/foo.bluebook` (legacy)
fn source_for_suite(suite_path: &str) -> String {
    let p = std::path::PathBuf::from(suite_path);
    let stem = p.file_stem().and_then(|s| s.to_str()).unwrap_or("");
    let source_stem = stem.trim_end_matches("_behavioral_tests");
    let parent = p.parent().map(|p| p.to_path_buf()).unwrap_or_else(|| std::path::PathBuf::from("."));
    parent.join(format!("{}.bluebook", source_stem)).to_string_lossy().into_owned()
}

/// heki subcommands — read/write + query shapes the shell scripts need.
///
/// Write/read (original):
///   hecks-life heki read   <file.heki>
///   hecks-life heki append <file.heki> key=val key2=val2
///   hecks-life heki upsert <file.heki> key=val key2=val2
///   hecks-life heki delete <file.heki> <id>
///   hecks-life heki latest <file.heki>
///
/// Query shapes (i37 Phase A — replace python3 -c invocations):
///   hecks-life heki get           <file.heki> <id> [<field>]
///   hecks-life heki list          <file.heki> [--where k=v]... [--order f[:asc|desc|enum=a,b,c]]
///                                             [--fields a,b,c] [--format json|tsv|kv]
///   hecks-life heki count         <file.heki> [--where k=v]...
///   hecks-life heki next-ref      <file.heki> [--prefix i] [--field ref]
///   hecks-life heki latest-field  <file.heki> <field>
///   hecks-life heki values        <file.heki> <field>
///   hecks-life heki mark          <file.heki> --where k=v [--where k=v]... --set k=v [--set k=v]...
///   hecks-life heki seconds-since <file.heki> <field>
///
/// Exit codes:
///   0 success
///   1 file not found / IO error
///   2 invalid filter / order syntax
///   3 field not found (get / latest-field / seconds-since)
///
/// [antibody-exempt: register new heki subcommand dispatchers; same
///  shape as existing run_heki arms]
fn run_heki(args: &[String]) {
    if args.len() < 4 {
        eprintln!("Usage: hecks-life heki <cmd> <file.heki> [args...]");
        eprintln!("Commands: read latest append upsert delete");
        eprintln!("          get list count next-ref latest-field values mark seconds-since");
        std::process::exit(1);
    }

    let sub = args[2].as_str();
    let file = args[3].as_str();
    let rest = &args[4..];

    match sub {
        "read"          => heki_cmd_read(file),
        "latest"        => heki_cmd_latest(file),
        "append"        => heki_cmd_append(file, rest),
        "upsert"        => heki_cmd_upsert(file, rest),
        "delete"        => heki_cmd_delete(file, rest),
        "get"           => heki_cmd_get(file, rest),
        "list"          => heki_cmd_list(file, rest),
        "count"         => heki_cmd_count(file, rest),
        "ids"           => heki_cmd_ids(file, rest),
        "next-ref"      => heki_cmd_next_ref(file, rest),
        "latest-field"  => heki_cmd_latest_field(file, rest),
        "values"        => heki_cmd_values(file, rest),
        "mark"          => heki_cmd_mark(file, rest),
        "seconds-since" => heki_cmd_seconds_since(file, rest),
        _ => {
            eprintln!("Unknown heki command: {}", sub);
            eprintln!("Available: read latest append upsert delete get list count ids \
                       next-ref latest-field values mark seconds-since");
            std::process::exit(1);
        }
    }
}

// -------- Existing read/write commands (extracted for readability) ---------

fn heki_cmd_read(file: &str) {
    match heki::read(file) {
        Ok(store) => println!("{}", serde_json::to_string_pretty(&store).unwrap_or_default()),
        Err(e)    => { eprintln!("{}", e); std::process::exit(1); }
    }
}

fn heki_cmd_latest(file: &str) {
    match heki::read(file) {
        Ok(store) => {
            match heki::latest(&store) {
                Some(rec) => println!("{}", serde_json::to_string_pretty(rec).unwrap_or_default()),
                None      => println!("{{}}"),
            }
        }
        Err(e) => { eprintln!("{}", e); std::process::exit(1); }
    }
}

fn heki_cmd_append(file: &str, rest: &[String]) {
    let attrs = heki::parse_attrs(rest);
    match heki::append(file, &attrs) {
        Ok(rec) => println!("{}", serde_json::to_string_pretty(&rec).unwrap_or_default()),
        Err(e)  => { eprintln!("{}", e); std::process::exit(1); }
    }
}

fn heki_cmd_upsert(file: &str, rest: &[String]) {
    let attrs = heki::parse_attrs(rest);
    match heki::upsert(file, &attrs) {
        Ok(rec) => println!("{}", serde_json::to_string_pretty(&rec).unwrap_or_default()),
        Err(e)  => { eprintln!("{}", e); std::process::exit(1); }
    }
}

fn heki_cmd_delete(file: &str, rest: &[String]) {
    let id = match rest.first() {
        Some(s) => s.as_str(),
        None => {
            eprintln!("Usage: hecks-life heki delete <file.heki> <id>");
            std::process::exit(1);
        }
    };
    match heki::delete(file, id) {
        Ok(true)  => println!("deleted {}", id),
        Ok(false) => { eprintln!("not found: {}", id); std::process::exit(1); }
        Err(e)    => { eprintln!("{}", e); std::process::exit(1); }
    }
}

// -------- New query commands ------------------------------------------------

fn heki_cmd_get(file: &str, rest: &[String]) {
    let id = match rest.first() {
        Some(s) => s.as_str(),
        None => {
            eprintln!("Usage: hecks-life heki get <file.heki> <id> [<field>]");
            std::process::exit(1);
        }
    };
    let field = rest.get(1).map(|s| s.as_str());

    let store = read_store_or_exit(file);
    let rec = match store.get(id) {
        Some(r) => r,
        None    => { eprintln!("no record with id {}", id); std::process::exit(1); }
    };
    match field {
        None => println!("{}", serde_json::to_string_pretty(rec).unwrap_or_default()),
        Some(f) => {
            if !rec.contains_key(f) {
                eprintln!("field not found: {}", f);
                std::process::exit(3);
            }
            println!("{}", heki_query::field_to_string(rec.get(f)));
        }
    }
}

fn heki_cmd_list(file: &str, rest: &[String]) {
    let opts = parse_query_opts(rest);
    let store = read_store_or_exit(file);

    let mut recs = heki_query::filter_records(&store, &opts.filters);
    let default_order = vec![heki_query::OrderSpec {
        field: "created_at".into(),
        dir: heki_query::OrderDir::Asc,
        enum_order: None,
        numeric_ref: false,
    }];
    let order_specs: &[heki_query::OrderSpec] = if opts.orders.is_empty() {
        &default_order
    } else {
        &opts.orders
    };
    recs = heki_query::order_records_multi(recs, order_specs);

    let fields = opts.fields.clone();
    match opts.format.as_str() {
        "tsv" => print_tsv(&recs, &fields),
        "kv"  => print_kv(&recs, &fields),
        _     => print_json(&recs, &fields),
    }
}

fn heki_cmd_count(file: &str, rest: &[String]) {
    let opts = parse_query_opts(rest);
    let store = read_store_or_exit(file);
    let recs = heki_query::filter_records(&store, &opts.filters);
    println!("{}", recs.len());
}

// List the aggregate IDs present in a heki store, one per line. Honors
// the same filter-flags as list/count (--where field=value) so callers
// can scope to a subset. Useful for debugging dispatches that miss : the
// dispatch may write to a default id like "1" while the existing record
// is keyed by a UUID, leaving the persisted state stale and the in-
// memory response misleading.
fn heki_cmd_ids(file: &str, rest: &[String]) {
    let opts = parse_query_opts(rest);
    let store = read_store_or_exit(file);
    let recs = heki_query::filter_records(&store, &opts.filters);
    for rec in &recs {
        if let Some(id) = rec.get("id").and_then(|v| v.as_str()) {
            println!("{}", id);
        }
    }
}

fn heki_cmd_next_ref(file: &str, rest: &[String]) {
    let mut prefix = "i".to_string();
    let mut field = "ref".to_string();
    let mut i = 0;
    while i < rest.len() {
        match rest[i].as_str() {
            "--prefix" => { prefix = rest.get(i+1).cloned().unwrap_or_default(); i += 2; }
            "--field"  => { field  = rest.get(i+1).cloned().unwrap_or_default(); i += 2; }
            _ => i += 1,
        }
    }

    let store = read_store_or_exit(file);
    let mut max_n: Option<i64> = None;
    for rec in store.values() {
        let v = heki_query::field_to_string(rec.get(&field));
        if let Some(tail) = v.strip_prefix(&prefix) {
            if let Ok(n) = tail.parse::<i64>() {
                max_n = Some(max_n.map_or(n, |cur| cur.max(n)));
            }
        }
    }
    let next = max_n.map_or(1, |n| n + 1);
    println!("{}{}", prefix, next);
}

fn heki_cmd_latest_field(file: &str, rest: &[String]) {
    let field = match rest.first() {
        Some(s) => s.as_str(),
        None => {
            eprintln!("Usage: hecks-life heki latest-field <file.heki> <field>");
            std::process::exit(1);
        }
    };
    let store = read_store_or_exit(file);
    match heki::latest(&store) {
        Some(rec) => {
            if !rec.contains_key(field) {
                eprintln!("field not found: {}", field);
                std::process::exit(3);
            }
            println!("{}", heki_query::field_to_string(rec.get(field)));
        }
        None => { /* empty store — print nothing, exit 0 */ }
    }
}

fn heki_cmd_values(file: &str, rest: &[String]) {
    let field = match rest.first() {
        Some(s) => s.as_str(),
        None => {
            eprintln!("Usage: hecks-life heki values <file.heki> <field>");
            std::process::exit(1);
        }
    };
    let store = read_store_or_exit(file);
    // Stable order — sort by created_at so output is deterministic.
    let spec = heki_query::OrderSpec {
        field: "created_at".into(),
        dir: heki_query::OrderDir::Asc,
        enum_order: None,
        numeric_ref: false,
    };
    let recs = heki_query::order_records(store.values().collect(), &spec);
    for rec in recs {
        if let Some(v) = rec.get(field) {
            println!("{}", heki_query::field_to_string(Some(v)));
        }
    }
}

fn heki_cmd_mark(file: &str, rest: &[String]) {
    let mut filters: Vec<heki_query::Filter> = Vec::new();
    let mut sets: Vec<(String, String)> = Vec::new();
    let mut i = 0;
    while i < rest.len() {
        match rest[i].as_str() {
            "--where" => {
                let spec = rest.get(i+1).cloned().unwrap_or_default();
                match heki_query::Filter::parse(&spec) {
                    Ok(f) => filters.push(f),
                    Err(e) => { eprintln!("{}", e); std::process::exit(2); }
                }
                i += 2;
            }
            "--set" => {
                let spec = rest.get(i+1).cloned().unwrap_or_default();
                match spec.find('=') {
                    Some(eq) => sets.push((spec[..eq].to_string(), spec[eq+1..].to_string())),
                    None => { eprintln!("invalid --set spec: {}", spec); std::process::exit(2); }
                }
                i += 2;
            }
            _ => i += 1,
        }
    }

    if filters.is_empty() {
        eprintln!("heki mark requires at least one --where");
        std::process::exit(2);
    }
    if sets.is_empty() {
        eprintln!("heki mark requires at least one --set");
        std::process::exit(2);
    }

    let mut store = read_store_or_exit(file);
    let ids: Vec<String> = store.iter()
        .filter(|(_, rec)| filters.iter().all(|f| f.matches(rec)))
        .map(|(id, _)| id.clone())
        .collect();
    let matched = ids.len();
    let now = heki::now_iso();
    for id in &ids {
        if let Some(rec) = store.get_mut(id) {
            for (k, v) in &sets {
                rec.insert(k.clone(), typed_value(v));
            }
            rec.insert("updated_at".into(), serde_json::Value::String(now.clone()));
        }
    }
    if matched > 0 {
        if let Err(e) = heki::write(file, &store) {
            eprintln!("{}", e);
            std::process::exit(1);
        }
    }
    println!("{}", matched);
}

fn heki_cmd_seconds_since(file: &str, rest: &[String]) {
    let field = match rest.first() {
        Some(s) => s.as_str(),
        None => {
            eprintln!("Usage: hecks-life heki seconds-since <file.heki> <field>");
            std::process::exit(1);
        }
    };
    let store = read_store_or_exit(file);
    let rec = match heki::latest(&store) {
        Some(r) => r,
        None    => { println!("0"); return; }
    };
    let ts = heki_query::field_to_string(rec.get(field));
    if ts.is_empty() {
        eprintln!("field not found or empty: {}", field);
        std::process::exit(3);
    }
    let secs = heki::seconds_since_iso(&ts);
    // Integer seconds — what the shell scripts want for -ge/-le compares.
    println!("{}", secs as i64);
}

// -------- Query option parsing (shared by list / count) --------------------

struct QueryOpts {
    filters: Vec<heki_query::Filter>,
    orders: Vec<heki_query::OrderSpec>,
    fields: Vec<String>,
    format: String,
}

fn parse_query_opts(rest: &[String]) -> QueryOpts {
    let mut filters: Vec<heki_query::Filter> = Vec::new();
    let mut orders: Vec<heki_query::OrderSpec> = Vec::new();
    let mut fields: Vec<String> = Vec::new();
    let mut format = "json".to_string();
    let mut i = 0;
    while i < rest.len() {
        match rest[i].as_str() {
            "--where" => {
                let spec = rest.get(i+1).cloned().unwrap_or_default();
                match heki_query::Filter::parse(&spec) {
                    Ok(f) => filters.push(f),
                    Err(e) => { eprintln!("{}", e); std::process::exit(2); }
                }
                i += 2;
            }
            "--order" => {
                let spec = rest.get(i+1).cloned().unwrap_or_default();
                match heki_query::OrderSpec::parse(&spec) {
                    Ok(o) => orders.push(o),
                    Err(e) => { eprintln!("{}", e); std::process::exit(2); }
                }
                i += 2;
            }
            "--fields" => {
                let spec = rest.get(i+1).cloned().unwrap_or_default();
                fields = spec.split(',').map(|s| s.to_string()).collect();
                i += 2;
            }
            "--format" => {
                format = rest.get(i+1).cloned().unwrap_or_else(|| "json".into());
                i += 2;
            }
            _ => i += 1,
        }
    }
    QueryOpts { filters, orders, fields, format }
}

fn read_store_or_exit(file: &str) -> heki::Store {
    match heki::read(file) {
        Ok(s) => s,
        Err(e) => { eprintln!("{}", e); std::process::exit(1); }
    }
}

/// `heki mark --set k=v` parses the value the same way `parse_attrs`
/// does — int / float / bool / string — so the shell doesn't have to
/// worry about quoting.
fn typed_value(v: &str) -> serde_json::Value {
    if let Ok(n) = v.parse::<i64>() {
        return serde_json::Value::Number(n.into());
    }
    if let Ok(f) = v.parse::<f64>() {
        return serde_json::json!(f);
    }
    if v == "true"  { return serde_json::Value::Bool(true);  }
    if v == "false" { return serde_json::Value::Bool(false); }
    serde_json::Value::String(v.to_string())
}

// -------- Output formats ---------------------------------------------------

fn project(rec: &heki::Record, fields: &[String]) -> serde_json::Value {
    if fields.is_empty() {
        return serde_json::to_value(rec).unwrap_or(serde_json::json!({}));
    }
    let mut map = serde_json::Map::new();
    for f in fields {
        if let Some(v) = rec.get(f) {
            map.insert(f.clone(), v.clone());
        } else {
            map.insert(f.clone(), serde_json::Value::Null);
        }
    }
    serde_json::Value::Object(map)
}

fn print_json(recs: &[&heki::Record], fields: &[String]) {
    let arr: Vec<serde_json::Value> = recs.iter().map(|r| project(r, fields)).collect();
    println!("{}", serde_json::to_string_pretty(&arr).unwrap_or_else(|_| "[]".into()));
}

fn print_tsv(recs: &[&heki::Record], fields: &[String]) {
    if fields.is_empty() {
        eprintln!("--format tsv requires --fields");
        std::process::exit(2);
    }
    for rec in recs {
        let row: Vec<String> = fields.iter()
            .map(|f| heki_query::field_to_string(rec.get(f)))
            .collect();
        println!("{}", row.join("\t"));
    }
}

fn print_kv(recs: &[&heki::Record], fields: &[String]) {
    for rec in recs {
        let keys: Vec<String> = if fields.is_empty() {
            let mut ks: Vec<String> = rec.keys().cloned().collect();
            ks.sort();
            ks
        } else {
            fields.to_vec()
        };
        for k in keys {
            println!("{}={}", k, heki_query::field_to_string(rec.get(&k)));
        }
        println!(); // blank line between records
    }
}

/// Canonical JSON for a `.hecksagon` file — matches the shape the Ruby
/// parity harness emits for `Hecksagon::Structure::Hecksagon#to_canonical_h`.
///
/// Only the subset the Rust IR models is included: name, persistence,
/// subscriptions, shell_adapters, io_adapters, gates. Ruby-side fields
/// outside that set (capabilities, concerns, annotations, context_map,
/// etc.) are intentionally NOT in the canonical shape — files that
/// depend on them go in hecksagon_known_drift.txt.
fn dump_hecksagon_json(hex: &hecks_life::hecksagon_ir::Hecksagon) -> serde_json::Value {
    let gates: Vec<serde_json::Value> = hex.gates.iter().map(|g| {
        serde_json::json!({
            "aggregate": g.aggregate,
            "role":      g.role,
            "allowed":   g.allowed_commands,
        })
    }).collect();
    let io_adapters: Vec<serde_json::Value> = hex.io_adapters.iter().map(|io| {
        let opts: Vec<serde_json::Value> = io.options.iter().map(|(k, v)| {
            serde_json::json!([k, v])
        }).collect();
        serde_json::json!({
            "kind":      io.kind,
            "options":   opts,
            "on_events": io.on_events,
        })
    }).collect();
    let shell_adapters: Vec<serde_json::Value> = hex.shell_adapters.iter().map(|sa| {
        let env: Vec<serde_json::Value> = sa.env.iter().map(|(k, v)| {
            serde_json::json!([k, v])
        }).collect();
        serde_json::json!({
            "name":          sa.name,
            "command":       sa.command,
            "args":          sa.args,
            "output_format": sa.output_format,
            "timeout":       sa.timeout,
            "working_dir":   sa.working_dir,
            "env":           env,
            "ok_exit":       sa.ok_exit,
        })
    }).collect();
    serde_json::json!({
        "name":           hex.name,
        "persistence":    hex.persistence,
        "subscriptions":  hex.subscriptions,
        "io_adapters":    io_adapters,
        "shell_adapters": shell_adapters,
        "gates":          gates,
    })
}

/// Canonical JSON for a `.world` file — matches the shape the Ruby
/// parity harness emits for `Hecksagon::Structure::World#to_canonical_h`.
fn dump_world_json(world: &hecks_life::world_ir::World) -> serde_json::Value {
    let concerns: Vec<serde_json::Value> = world.concerns.iter().map(|c| {
        serde_json::json!({
            "name": c.name,
            "description": c.description,
        })
    }).collect();
    let mut configs = serde_json::Map::new();
    for cfg in &world.configs {
        let mut obj = serde_json::Map::new();
        for (k, v) in &cfg.values {
            obj.insert(k.clone(), serde_json::Value::String(v.clone()));
        }
        configs.insert(cfg.name.clone(), serde_json::Value::Object(obj));
    }
    serde_json::json!({
        "name":     world.name,
        "purpose":  world.purpose,
        "vision":   world.vision,
        "audience": world.audience,
        "concerns": concerns,
        "configs":  configs,
    })
}

/// Derive the being name from argv[0].
/// "miette" or "/path/to/miette" -> "Miette"
/// "summer" or "/path/to/summer" -> "Summer"
/// Anything else (hecks-life, etc) -> "Miette" (default)
fn being_from_argv0(argv0: &str) -> String {
    let bin = std::path::Path::new(argv0)
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("miette");
    match bin {
        "summer" => "Summer".into(),
        "miette" => "Miette".into(),
        _ => "Miette".into(),
    }
}

/// Locate a domain-named `*.world` file in the given directory.
/// Returns the first match sorted alphabetically so behavior is deterministic.
fn find_world_file(dir: &std::path::Path) -> Option<std::path::PathBuf> {
    let mut matches: Vec<std::path::PathBuf> = fs::read_dir(dir).ok()?
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.extension().map(|e| e == "world").unwrap_or(false))
        .collect();
    matches.sort();
    matches.into_iter().next()
}

/// Read ollama config from the project's *.world file — returns
/// (model, url) if configured. Routes through world_parser so there is
/// one canonical shape for all .world consumers.
fn find_world_ollama_config(agg_path: &str) -> Option<(String, String)> {
    let parent = std::path::Path::new(agg_path).parent()?;
    let world_path = find_world_file(parent)?;
    let content = fs::read_to_string(&world_path).ok()?;
    let world = hecks_life::world_parser::parse(&content);
    let cfg = world.config_for("ollama")?;
    let model = cfg.get("model")?.to_string();
    let url   = cfg.get("url")?.to_string();
    Some((model, url))
}

/// Scan every `*.hecksagon` in `agg_dir` for an `adapter :llm,
/// backend: :X` declaration. Returns the (backend, model, url) triple
/// the LLM adapter expects — model and url are pulled from the world's
/// `ollama { model:, url: }` block when present so the ollama backend
/// stays wired ; for the claude backend, model/url are ignored by the
/// adapter and we pass empty strings.
///
/// This is the runtime side of the contract `wake_review.hecksagon`
/// and `interpretation.hecksagon` and `rem_dream.hecksagon` already
/// declare in bluebook : `adapter :llm, backend: :claude`. Without
/// this scan, dispatch only honored ollama-from-world ; with it, the
/// hecksagon's declaration is the source of truth and Compose/Narrate
/// fire end-to-end via bluebook.
///
/// Returns None when no `:llm` adapter is declared (so the existing
/// ollama-from-world path stays the default for conversational
/// dispatch).
fn find_hecksagon_llm_config(agg_dir: &str) -> Option<(String, String, String)> {
    let entries = fs::read_dir(agg_dir).ok()?;
    for entry in entries.flatten() {
        let p = entry.path();
        if !p.extension().map(|e| e == "hecksagon").unwrap_or(false) { continue; }
        let Ok(source) = fs::read_to_string(&p) else { continue };
        let hex = hecks_life::hecksagon_parser::parse(&source);
        let Some(io) = hex.io_adapter("llm") else { continue };
        let backend = io.options.iter()
            .find(|(k, _)| k == "backend")
            .map(|(_, v)| strip_symbol_or_quotes(v))
            .unwrap_or_else(|| "ollama".to_string());
        // For ollama backend we still need (model, url) ; pull from
        // .world if available, otherwise empty (resolve will skip).
        let (model, url) = find_world_ollama_config(agg_dir)
            .unwrap_or_else(|| (String::new(), String::new()));
        return Some((backend, model, url));
    }
    None
}

/// Strip a leading `:` or surrounding quotes from a hecksagon option
/// value. Mirrors the symbol/quote handling in hecksagon_helpers but
/// kept inline-tiny so main.rs doesn't grow a helpers dep.
fn strip_symbol_or_quotes(v: &str) -> String {
    let t = v.trim();
    if let Some(rest) = t.strip_prefix(':') { return rest.to_string(); }
    let t = t.trim_matches('"').trim_matches('\'');
    t.to_string()
}

/// Boot the hecksagon and run the terminal adapter.
fn run_terminal(project_dir: &str, being: &str) {
    let agg_dir = format!("{}/aggregates", project_dir);
    let data_dir = find_world_heki_dir(&agg_dir)
        .unwrap_or_else(|| format!("{}/information", project_dir));
    let mut combined = hecks_life::ir::Domain {
        name: "Hecksagon".into(),
        category: None, vision: None,
        aggregates: vec![], policies: vec![],
        fixtures: vec![],
        entrypoint: None,
        sections: vec![],
    };
    if let Ok(entries) = fs::read_dir(&agg_dir) {
        for entry in entries.flatten() {
            let p = entry.path();
            if p.extension().map(|e| e == "bluebook").unwrap_or(false) {
                if let Ok(source) = fs::read_to_string(&p) {
                    let domain = parser::parse(&source);
                    combined.aggregates.extend(domain.aggregates);
                    combined.policies.extend(domain.policies);
                    combined.fixtures.extend(domain.fixtures);
                }
            }
        }
    }
    let mut rt = Runtime::boot_with_data_dir(combined, Some(data_dir));
    hecks_life::runtime::adapter_terminal::run(&mut rt, being);
}

/// Find the heki dir from the project's *.world file — look in parent of
/// the given path. Routes through world_parser so the .world grammar has
/// exactly one definition.
fn find_world_heki_dir(aggregates_path: &str) -> Option<String> {
    // HECKS_INFO env var wins unconditionally — lets Miette's state
    // live in a private repo (~/Projects/miette-state/information)
    // while the framework stays public. Same override pattern used
    // by run_status/mod.rs. See hecks_conception/information/README.md.
    if let Ok(override_dir) = std::env::var("HECKS_INFO") {
        if !override_dir.is_empty() {
            return Some(override_dir);
        }
    }
    let parent = std::path::Path::new(aggregates_path).parent()?;
    let world_path = find_world_file(parent)?;
    let content = fs::read_to_string(&world_path).ok()?;
    let world = hecks_life::world_parser::parse(&content);
    let heki = world.config_for("heki")?;
    let dir = heki.get("dir")?;
    Some(parent.join(dir).to_string_lossy().into_owned())
}

/// Dispatch a command through the hecksagon — merge all bluebooks, find the command, run it.
fn dispatch_hecksagon(agg_dir: &str, command: &str, attrs: std::collections::HashMap<String, serde_json::Value>) {
    let data_dir = find_world_heki_dir(agg_dir)
        .unwrap_or_else(|| format!("{}/data", agg_dir.trim_end_matches('/')));
    let mut combined = hecks_life::ir::Domain {
        name: "Hecksagon".into(),
        category: None, vision: None,
        aggregates: vec![], policies: vec![],
        fixtures: vec![],
        entrypoint: None,
        sections: vec![],
    };
    let entries = fs::read_dir(agg_dir).unwrap_or_else(|e| {
        eprintln!("Cannot read directory {}: {}", agg_dir, e);
        std::process::exit(1);
    });
    for entry in entries.flatten() {
        let p = entry.path();
        if p.extension().map(|e| e == "bluebook").unwrap_or(false) {
            if let Ok(source) = fs::read_to_string(&p) {
                let domain = parser::parse(&source);
                combined.aggregates.extend(domain.aggregates);
                combined.policies.extend(domain.policies);
                combined.fixtures.extend(domain.fixtures);
            }
        }
    }
    let mut rt = Runtime::boot_with_data_dir(combined, Some(data_dir));

    // Check if this is a query — find the aggregate and check its queries
    let is_query = rt.domain.aggregates.iter().any(|a|
        a.queries.iter().any(|q| q.name == command));

    if is_query {
        let result = rt.resolve_query(command, &attrs.iter()
            .map(|(k, v)| (k.clone(), v.as_str().unwrap_or("").to_string()))
            .collect::<std::collections::HashMap<_, _>>());
        println!("{}", result);
    } else {
        // Command: dispatch, mutate, run adapters, return state.
        //
        // LLM config resolution :
        //   1. Hecksagon-declared `adapter :llm, backend: :X` wins (i109
        //      runtime gap closure ; the source of truth is the
        //      bluebook surface, not .world). Backends: "claude" (no
        //      model/url needed) or "ollama" (uses world model/url).
        //   2. Otherwise, fall back to .world's ollama block — the
        //      legacy conversational path that long predates the
        //      hecksagon :llm declaration.
        let hecksagon_llm = find_hecksagon_llm_config(agg_dir);
        let ollama_config = find_world_ollama_config(agg_dir);
        let rt_attrs: std::collections::HashMap<String, hecks_life::runtime::Value> = attrs.iter()
            .map(|(k, v)| (k.clone(), match v {
                serde_json::Value::String(s) => hecks_life::runtime::Value::Str(s.clone()),
                _ => hecks_life::runtime::Value::Str(v.to_string()),
            }))
            .collect();
        match rt.dispatch(command, rt_attrs) {
            Ok(result) => {
                // Run LLM adapter if configured
                if let Some(state) = rt.find(&result.aggregate_type, &result.aggregate_id).cloned() {
                    if let Some(repo) = rt.repositories.get_mut(&result.aggregate_type) {
                        if let Some((backend, model, url)) = hecksagon_llm.as_ref() {
                            let triple = (backend.as_str(), model.as_str(), url.as_str());
                            hecks_life::runtime::adapter_llm::resolve(repo, &state, Some(triple));
                        } else {
                            let config = ollama_config.as_ref().map(|(m, u)| (m.as_str(), u.as_str()));
                            hecks_life::runtime::adapter_llm::resolve_ollama(repo, &state, config);
                        }
                    }
                }
                let state = rt.find(&result.aggregate_type, &result.aggregate_id);
                let fields = state.map(|s| {
                    let mut map = serde_json::Map::new();
                    for (k, v) in &s.fields {
                        map.insert(k.clone(), match v {
                            hecks_life::runtime::Value::Str(s) => serde_json::json!(s),
                            hecks_life::runtime::Value::Int(n) => serde_json::json!(n),
                            hecks_life::runtime::Value::Bool(b) => serde_json::json!(b),
                            _ => serde_json::json!(v.to_string()),
                        });
                    }
                    serde_json::Value::Object(map)
                }).unwrap_or(serde_json::json!({}));
                println!("{}", serde_json::json!({
                    "ok": true,
                    "aggregate": result.aggregate_type,
                    "id": result.aggregate_id,
                    "state": fields,
                }));
            }
            Err(e) => {
                eprintln!("dispatch error: {:?}", e);
                std::process::exit(1);
            }
        }
    }
}

/// Parse a loop-cadence duration string.
///
/// Accepts "1s", "500ms", "2m", "5h", or a bare integer (treated as
/// seconds for backwards compat). Returns None if unparseable.
///
/// The unit suffix order matters — "ms" must be checked before "s"
/// so "500ms" doesn't match "500m"+"s". Same for "h" before "ms"
/// (no overlap, but explicit ordering is safer).
fn parse_loop_duration(s: &str) -> Option<std::time::Duration> {
    use std::time::Duration;
    let s = s.trim();
    if let Some(ms) = s.strip_suffix("ms") {
        ms.trim().parse::<u64>().ok().map(Duration::from_millis)
    } else if let Some(h) = s.strip_suffix("h") {
        h.trim().parse::<u64>().ok().map(|n| Duration::from_secs(n * 3600))
    } else if let Some(m) = s.strip_suffix("m") {
        m.trim().parse::<u64>().ok().map(|n| Duration::from_secs(n * 60))
    } else if let Some(sec) = s.strip_suffix("s") {
        sec.trim().parse::<f64>().ok().map(Duration::from_secs_f64)
    } else {
        s.parse::<u64>().ok().map(Duration::from_secs)
    }
}

/// Run the loop subcommand. Boots the runtime once, dispatches the named
/// command at the given cadence, exits cleanly on SIGINT / SIGTERM.
///
/// Args layout : hecks-life loop <target> <Aggregate.Command> --every <dur> [k=v ...]
///   args[0] = binary
///   args[1] = "loop"
///   args[2] = target (agg dir or .bluebook)
///   args[3] = "Aggregate.Command"
///   args[4..] = "--every", "<dur>", and key=val attrs
// ============================================================
// DAEMON SUBCOMMAND — process-lifecycle primitive
// ============================================================
//
// Three actions, each idempotent against a pidfile :
//
//   ensure <pidfile> <command> [args...]
//     If pidfile exists and the PID is alive, prints `alive: <pid>`
//     and exits 0 (idempotent boot — same shape as the existing
//     boot_miette.sh `kill -0` checks). Otherwise spawns the command
//     in a new session (setsid) with stdio routed to /dev/null, writes
//     the child's PID to the pidfile, prints `spawned: <pid>` and exits 0.
//
//     The setsid call is what makes this NOT leak. The wrapping subshell
//     pattern (`( cd ... && nohup ./script & )`) used in boot_miette.sh
//     today produces PPID=1 orphans on macOS because the wrapper bash
//     shell doesn't always exit cleanly after backgrounding. Spawning
//     directly via Command + pre_exec(setsid) puts the daemon in its
//     own session/process-group and the parent (this hecks-life process)
//     exits immediately — no wrapping shell to leak.
//
//   status <pidfile>
//     Prints `alive: <pid>` (exit 0), `dead: <pid>` (exit 1), or
//     `none` (exit 1). For health-check use (i94).
//
//   stop <pidfile>
//     If the PID is alive, sends SIGTERM and prints `stopped: <pid>`.
//     Removes the pidfile.

// ============================================================
// ENFORCE-EDIT SUBCOMMAND — PostToolUse listener primitive
// ============================================================
//
// Reads JSON from stdin (Claude Code's PostToolUse contract),
// extracts tool_name and tool_input.file_path, classifies the
// extension, dispatches into the Enforcer aggregate, and routes
// imperative-edit complaints back to the agent via stderr + exit 2.
//
// Replaces ~/.claude/hooks/enforce_bluebook.sh (i104). Same family
// as run_loop / run_daemon : kernel-surface CLI primitive that a
// bluebook capability dispatches into. Bluebook brain
// (aggregates/enforcer.bluebook) stays unchanged ; the shell glue
// retires.

fn run_enforce_edit(_args: &[String]) {
    use std::io::Read;
    let mut input = String::new();
    if std::io::stdin().read_to_string(&mut input).is_err() {
        std::process::exit(0);
    }
    let json: serde_json::Value = match serde_json::from_str(&input) {
        Ok(v) => v,
        Err(_) => std::process::exit(0),
    };
    let tool_name = json.get("tool_name")
        .and_then(|v| v.as_str()).unwrap_or("").to_string();
    let file_path = json.pointer("/tool_input/file_path")
        .and_then(|v| v.as_str()).unwrap_or("").to_string();
    if file_path.is_empty() {
        std::process::exit(0);
    }

    let kind = classify_file(&file_path);
    let cmd_name = match kind {
        FileKind::Bluebook   => "RecordBluebookEdit",
        FileKind::Imperative => "RecordImperativeEdit",
        FileKind::Support    => "RecordSupportEdit",
        FileKind::Other      => "RecordOtherEdit",
    };

    // Resolve aggregates dir relative to the binary's project layout.
    // Same path the rest of the body uses.
    let agg_dir = match resolve_aggregates_dir() {
        Some(p) => p,
        None    => std::process::exit(0),
    };

    let mut attrs = std::collections::HashMap::new();
    attrs.insert("file_path".to_string(), serde_json::Value::String(file_path.clone()));
    let _ = std::panic::catch_unwind(|| {
        // dispatch_hecksagon expects the bare command name (no
        // "Aggregate." prefix) ; the runtime resolves by command-
        // name within the loaded domain. Same shape run_loop uses.
        dispatch_hecksagon(&agg_dir, cmd_name, attrs.clone());
    });

    if matches!(kind, FileKind::Imperative) {
        let ext = file_path.rsplit('.').next().unwrap_or("");
        let complaint = format!(
            "bluebook-first violation : {} wrote .{} ({}). The enforcer expected a \
             bluebook (.bluebook / .hecksagon / .fixtures / .behaviors / .world). If \
             this is genuinely kernel-surface or transitional, name the exemption in \
             the file's antibody marker AND in the next commit's message ; otherwise, \
             revert and reach for bluebook.",
            tool_name, ext, file_path
        );
        let ts = chrono_utc_now();
        let mut complain_attrs = std::collections::HashMap::new();
        complain_attrs.insert("file_path".into(), serde_json::Value::String(file_path));
        complain_attrs.insert("complaint".into(), serde_json::Value::String(complaint.clone()));
        complain_attrs.insert("last_complaint_at".into(), serde_json::Value::String(ts));
        let _ = std::panic::catch_unwind(|| {
            dispatch_hecksagon(&agg_dir, "Complain", complain_attrs);
        });
        eprintln!("[enforcer] {}", complaint);
        std::process::exit(2);
    }
    std::process::exit(0);
}

enum FileKind { Bluebook, Imperative, Support, Other }

fn classify_file(path: &str) -> FileKind {
    let ext = path.rsplit('.').next().unwrap_or("").to_lowercase();
    match ext.as_str() {
        "bluebook" | "hecksagon" | "fixtures" | "behaviors" | "world" => FileKind::Bluebook,
        "rs" | "sh" | "rb" | "js" | "jsx" | "ts" | "tsx"
            | "py" | "go" | "c" | "cpp" | "h" | "hpp" | "java" | "swift" => FileKind::Imperative,
        "md" | "heki" | "json" | "toml" | "yaml" | "yml" | "txt" => FileKind::Support,
        _ => FileKind::Other,
    }
}

fn resolve_aggregates_dir() -> Option<String> {
    // HECKS_HOME points at the repo root (sibling of hecks_conception
    // and hecks_life), not at hecks_conception itself.
    if let Ok(home) = env::var("HECKS_HOME") {
        let p = format!("{}/hecks_conception/aggregates", home);
        if std::path::Path::new(&p).is_dir() { return Some(p); }
    }
    // Walk up from the binary :
    //   /…/hecks/hecks_life/target/release/hecks-life
    //   .parent() = release
    //   .parent() = target
    //   .parent() = hecks_life
    //   .parent() = hecks (repo root)
    if let Ok(exe) = env::current_exe() {
        if let Ok(real) = exe.canonicalize() {
            if let Some(repo) = real.parent()
                .and_then(|p| p.parent())
                .and_then(|p| p.parent())
                .and_then(|p| p.parent())
            {
                let agg = repo.join("hecks_conception").join("aggregates");
                if agg.is_dir() {
                    return Some(agg.to_string_lossy().into_owned());
                }
            }
        }
    }
    None
}

fn chrono_utc_now() -> String {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64).unwrap_or(0);
    // Inline ISO-8601 — avoids pulling chrono crate just for this.
    let (year, month, day, hour, min, sec) = ymdhms_from_unix(now);
    format!("{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z", year, month, day, hour, min, sec)
}

/// Convert unix seconds to UTC y/m/d/h/m/s. Howard Hinnant's algorithm.
fn ymdhms_from_unix(secs: i64) -> (i64, i64, i64, i64, i64, i64) {
    let z = secs / 86400;
    let s = secs.rem_euclid(86400);
    let hour = s / 3600;
    let min = (s % 3600) / 60;
    let sec = s % 60;
    let z_shift = z + 719468;
    let era = if z_shift >= 0 { z_shift } else { z_shift - 146096 } / 146097;
    let doe = (z_shift - era * 146097) as i64;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = if month <= 2 { y + 1 } else { y };
    (year, month, day, hour, min, sec)
}

fn run_daemon(args: &[String]) {
    let action = args.get(2).map(|s| s.as_str()).unwrap_or_else(|| {
        eprintln!("Usage: hecks-life daemon <ensure|status|stop> <pidfile> [command...]");
        std::process::exit(1);
    });
    match action {
        "ensure" => daemon_ensure(&args[3..]),
        "status" => daemon_status(&args[3..]),
        "stop"   => daemon_stop(&args[3..]),
        _ => {
            eprintln!("Unknown daemon action: {}", action);
            eprintln!("Usage: hecks-life daemon <ensure|status|stop> <pidfile> [command...]");
            std::process::exit(1);
        }
    }
}

fn daemon_ensure(rest: &[String]) {
    let pidfile = rest.first().map(|s| s.as_str()).unwrap_or_else(|| {
        eprintln!("Usage: hecks-life daemon ensure <pidfile> <command> [args...]");
        std::process::exit(1);
    });
    if let Some(pid) = read_pidfile(pidfile) {
        if pid_alive(pid) {
            println!("alive: {}", pid);
            return;
        }
    }
    if rest.len() < 2 {
        eprintln!("daemon ensure : need <command> after <pidfile>");
        std::process::exit(1);
    }
    let cmd = &rest[1];
    let cmd_args = &rest[2..];
    match spawn_detached(cmd, cmd_args) {
        Ok(pid) => {
            if let Err(e) = write_pidfile(pidfile, pid) {
                eprintln!("warning: spawned pid {} but pidfile write failed: {}", pid, e);
            }
            println!("spawned: {}", pid);
        }
        Err(e) => {
            eprintln!("spawn failed: {}", e);
            std::process::exit(1);
        }
    }
}

fn daemon_status(rest: &[String]) {
    let pidfile = rest.first().map(|s| s.as_str()).unwrap_or_else(|| {
        eprintln!("Usage: hecks-life daemon status <pidfile>");
        std::process::exit(1);
    });
    match read_pidfile(pidfile) {
        Some(pid) if pid_alive(pid) => println!("alive: {}", pid),
        Some(pid) => { println!("dead: {}", pid); std::process::exit(1); }
        None => { println!("none"); std::process::exit(1); }
    }
}

fn daemon_stop(rest: &[String]) {
    let pidfile = rest.first().map(|s| s.as_str()).unwrap_or_else(|| {
        eprintln!("Usage: hecks-life daemon stop <pidfile>");
        std::process::exit(1);
    });
    match read_pidfile(pidfile) {
        Some(pid) if pid_alive(pid) => {
            extern "C" { fn kill(pid: i32, sig: i32) -> i32; }
            unsafe { kill(pid as i32, 15); } // SIGTERM
            println!("stopped: {}", pid);
            let _ = std::fs::remove_file(pidfile);
        }
        Some(_) => {
            println!("not running");
            let _ = std::fs::remove_file(pidfile);
        }
        None => {
            println!("no pidfile");
            std::process::exit(1);
        }
    }
}

fn read_pidfile(path: &str) -> Option<u32> {
    std::fs::read_to_string(path).ok()
        .and_then(|s| s.trim().parse().ok())
}

fn write_pidfile(path: &str, pid: u32) -> std::io::Result<()> {
    std::fs::write(path, format!("{}\n", pid))
}

fn pid_alive(pid: u32) -> bool {
    extern "C" { fn kill(pid: i32, sig: i32) -> i32; }
    unsafe { kill(pid as i32, 0) == 0 }
}

fn spawn_detached(cmd: &str, args: &[String]) -> std::io::Result<u32> {
    use std::os::unix::process::CommandExt;
    use std::process::{Command, Stdio};
    extern "C" { fn setsid() -> i32; }

    let mut command = Command::new(cmd);
    command
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    unsafe {
        command.pre_exec(|| {
            setsid();
            Ok(())
        });
    }
    let child = command.spawn()?;
    Ok(child.id())
}

fn run_loop(args: &[String]) {
    let target = args.get(2).map(|s| s.as_str()).unwrap_or_else(|| {
        eprintln!("Usage: hecks-life loop <bluebook-or-dir> <Aggregate.Command> --every <duration> [key=val ...]");
        std::process::exit(1);
    });
    let cmd_full = args.get(3).map(|s| s.as_str()).unwrap_or_else(|| {
        eprintln!("loop : missing <Aggregate.Command>");
        std::process::exit(1);
    });
    let every_str = args.iter().position(|a| a == "--every")
        .and_then(|i| args.get(i + 1))
        .map(|s| s.as_str())
        .unwrap_or_else(|| {
            eprintln!("loop : missing --every <duration> (e.g. 1s, 500ms, 2m)");
            std::process::exit(1);
        });
    let every = parse_loop_duration(every_str).unwrap_or_else(|| {
        eprintln!("loop : cannot parse --every '{}' (try 1s, 500ms, 2m)", every_str);
        std::process::exit(1);
    });

    // Strip "Aggregate." prefix from cmd_full so the runtime gets just the command name.
    let cmd_name = cmd_full.split('.').last().unwrap_or(cmd_full).to_string();

    // Parse trailing key=val attrs, skipping the --every flag and its value.
    let mut attrs: std::collections::HashMap<String, hecks_life::runtime::Value> = Default::default();
    let mut i = 4;
    while i < args.len() {
        if args[i] == "--every" { i += 2; continue; }
        if args[i].starts_with("--") { i += 1; continue; }
        let mut parts = args[i].splitn(2, '=');
        if let (Some(k), Some(v)) = (parts.next(), parts.next()) {
            attrs.insert(k.to_string(), hecks_life::runtime::Value::Str(v.to_string()));
        }
        i += 1;
    }

    eprintln!(
        "[hecks-life loop] {} every {:?} (Ctrl-C to stop)",
        cmd_full, every
    );

    // Build the combined domain ONCE (parse all bluebooks in the target),
    // boot the runtime ONCE, then loop dispatching. This is the speedup
    // over the shell `while true ; do hecks-life agg/ Cmd ; sleep N ; done`
    // pattern, which paid full parse + boot per iteration.
    let data_dir = find_world_heki_dir(target)
        .unwrap_or_else(|| format!("{}/data", target.trim_end_matches('/')));
    let domain = if std::path::Path::new(target).is_dir() {
        let mut combined = hecks_life::ir::Domain {
            name: "Loop".into(),
            category: None, vision: None,
            aggregates: vec![], policies: vec![],
            fixtures: vec![], entrypoint: None,
            sections: vec![],
        };
        for entry in fs::read_dir(target).unwrap_or_else(|e| {
            eprintln!("Cannot read {}: {}", target, e); std::process::exit(1);
        }).flatten() {
            let p = entry.path();
            if p.extension().map(|e| e == "bluebook").unwrap_or(false) {
                if let Ok(source) = fs::read_to_string(&p) {
                    let d = parser::parse(&source);
                    combined.aggregates.extend(d.aggregates);
                    combined.policies.extend(d.policies);
                    combined.fixtures.extend(d.fixtures);
                }
            }
        }
        combined
    } else {
        let source = fs::read_to_string(target).unwrap_or_else(|e| {
            eprintln!("Cannot read {}: {}", target, e); std::process::exit(1);
        });
        parser::parse(&source)
    };

    let mut rt = Runtime::boot_with_data_dir(domain, Some(data_dir));
    loop {
        if let Err(e) = rt.dispatch(&cmd_name, attrs.clone()) {
            eprintln!("[hecks-life loop] dispatch error: {:?}", e);
        }
        std::thread::sleep(every);
    }
}

/// Resolve the project home directory for a named being.
/// 1. HECKS_HOME env var
/// 2. ~/.hecks_home file (single line: path to hecks_conception)
/// 3. Follow symlink from the binary to hecks_life/../hecks_conception
/// 4. Fall back to "."
fn resolve_home(_being: &str) -> String {
    // Check env var first
    if let Ok(home) = env::var("HECKS_HOME") {
        return home;
    }
    // Check ~/.hecks_home file
    if let Ok(home_dir) = env::var("HOME") {
        let home_file = format!("{}/.hecks_home", home_dir);
        eprintln!("  resolve_home: checking {}", home_file);
        match fs::read_to_string(&home_file) {
            Ok(contents) => {
                let path = contents.trim().to_string();
                eprintln!("  resolve_home: found path={}", path);
                if std::path::Path::new(&path).is_dir() {
                    return path;
                }
                eprintln!("  resolve_home: path is not a dir");
            }
            Err(e) => eprintln!("  resolve_home: read error: {}", e),
        }
    } else {
        eprintln!("  resolve_home: HOME not set");
    }
    // Try to resolve from the binary's real location
    // binary lives at hecks_life/target/release/hecks-life
    // project lives at hecks_conception (sibling of hecks_life)
    if let Ok(exe) = env::current_exe() {
        if let Ok(real) = exe.canonicalize() {
            if let Some(hecks2) = real.parent().and_then(|p| p.parent()).and_then(|p| p.parent()) {
                let conception = hecks2.join("hecks_conception");
                if conception.is_dir() {
                    return conception.to_string_lossy().into_owned();
                }
            }
        }
    }
    ".".into()
}

fn dirs() -> Option<String> {
    env::var("HOME").ok()
}

fn print_usage() {
    eprintln!("hecks-life — the Bluebook compiler and runtime\n");
    eprintln!("Usage: hecks-life <command> <bluebook-file> [options]\n");
    eprintln!("Commands:");
    eprintln!("  parse      Parse and print domain summary");
    eprintln!("  validate   Check domain for DDD consistency");
    eprintln!("  inspect    Full domain inspection with all details");
    eprintln!("  tree       Tree view of aggregates and commands");
    eprintln!("  list       Summary list of aggregates and commands");
    eprintln!("  run        Execute a bluebook as an executable (shebang-run)");
    eprintln!("  repl       Boot runtime with interactive REPL (legacy `run`)");
    eprintln!("  serve      Boot runtime as HTTP JSON API (file or directory)");
    eprintln!("  conceive   Generate a new domain from corpus archetypes");
    eprintln!("  develop    Develop features in an existing domain");
    eprintln!("  boot       Full boot: hydrate + nerves + prompt gen");
    eprintln!("  daemon     Run background daemons (pulse, daydream, sleep)");
    eprintln!("  hydrate    Load .heki stores and print vital signs");
    eprintln!("  heki       Read/write .heki binary stores");
    eprintln!("  dump-world Parse a .world file and emit canonical JSON");
    eprintln!("  dump-hecksagon  Parse a .hecksagon file and emit canonical JSON\n");
    eprintln!("Heki subcommands:");
    eprintln!("  heki read   <file>           Dump store as JSON");
    eprintln!("  heki latest <file>           Show latest record");
    eprintln!("  heki append <file> k=v ...   Append new record");
    eprintln!("  heki upsert <file> k=v ...   Upsert singleton");
    eprintln!("  heki delete <file> <id>      Delete record by ID\n");
    eprintln!("Options:");
    eprintln!("  --seed <file>      Load seed commands at boot (run/serve)");
    eprintln!("  --corpus <dirs>    Corpus directories (conceive/develop)");
    eprintln!("  --add <feature>    Feature to add (develop)");
    eprintln!("  --from <path>      Source archetype bluebook (develop)");
}

/// Emits soft validator warnings to stderr — advisories, never failures.
///
/// Wires the four functions in `validator_warnings.rs` (the bluebook-declared
/// rules from `capabilities/validator_warnings_shape/`) into the dispatch arms
/// that touch a parsed Domain. Stays on stderr so parity tests and pipelines
/// keep reading clean stdout.
fn emit_validator_warnings_to_stderr(domain: &hecks_life::ir::Domain) {
    if let Some(msg) = validator_warnings::aggregate_count_warning(domain)   { eprintln!("{}", msg); }
    if let Some(msg) = validator_warnings::multi_domain_split_warning(domain) { eprintln!("{}", msg); }
    if let Some(msg) = validator_warnings::mixed_concerns_warning(domain)    { eprintln!("{}", msg); }
    if let Some(msg) = validator_warnings::bluebook_size_warning(domain)     { eprintln!("{}", msg); }
}
