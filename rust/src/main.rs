//! Hecks Life — the Bluebook compiler and runtime
//!
//! Reads .bluebook files, parses them into IR, and executes them.
//! The Bluebook is DNA. This is the ribosome. The runtime is life.
//!
//! [antibody-exempt: rust/src/main.rs — wires the :llm hecksagon
//!  adapter into dispatch_hecksagon. This IS the structural rewrite
//!  that lets wake_review and interpret_dream fire end-to-end via
//!  bluebook. Same i80 retirement contract ; closes the i109 :llm
//!  runtime gap that PR #455 explicitly named. Rewriting IS the work.]
//!
//! Usage:
//!   storehouse parse     pizzas.bluebook
//!   storehouse validate  pizzas.bluebook
//!   storehouse inspect   pizzas.bluebook
//!   storehouse tree      pizzas.bluebook
//!   storehouse list      pizzas.bluebook
//!   storehouse run       pizzas.bluebook [--seed seeds.txt]
//!   storehouse serve     pizzas.bluebook [--seed seeds.txt] [port]
//!   storehouse serve     path/to/hecks/ [port]
//!   storehouse conceive  "Name" "vision" --corpus dir1 dir2
//!   storehouse develop   target.bluebook --add "feature"
//!
//! [antibody-exempt: rust/src/main.rs — wires validator_warnings into
//!  dispatch arms. This IS the structural rewrite that closes the gap
//!  between the bluebook-declared rules (capabilities/validator_warnings_shape/)
//!  and runtime enforcement. Same i80 retirement contract as run_loop /
//!  run_daemon / run_macrophage. Net ~12 LoC.]
//!
//! [antibody-exempt: rust/src/main.rs — closes i113 (sleep-as-blocking-
//!  streaming-command). Wires Consciousness.EnterSleep dispatch + heki polling
//!  + dream stream + wake-report read into a single blocking CLI. Same kernel-
//!  surface family as run_loop / run_daemon / run_macrophage ; same i80
//!  retirement contract — retires once cli.bluebook lands and CLI routing
//!  becomes declarative.]
//!
//! [antibody-exempt: rust/src/main.rs — closes i118 (macrophage-honors-
//!  in-file-antibody-exempt-markers). run_macrophage now reads the touched
//!  file's first 200 lines and dispatches Macrophage.RecordExemptedEdit (silent
//!  exit 0) instead of Macrophage.Complain when the file already carries a
//!  marker. The marker IS the audit trail. Same i80 retirement contract as
//!  the rest of the run_macrophage family.]
//!
//! [antibody-exempt: rust/src/main.rs detect_bash_write_target +
//!  scan_command_with_path_arg — 2026-05-02 false-positive heal. The prior
//!  classifier treated `sed -n '...'` (autoprint-suppress, read-only) as a
//!  write target whenever any flag was present, blocking honest reads of
//!  .rs files. New shape : each cmd_name names the exact write signatures
//!  (None for tee/always-write ; Some(&[bigrams]) for sed -i / --in-place
//!  and awk -i inplace). Same i80 retirement contract as the rest of the
//!  run_macrophage family — retires when the macrophage's command-string
//!  classification becomes a domain dispatched from
//!  aggregates/discipline/macrophage/.]
//!
//! [antibody-exempt: rust/src/main.rs — i117 Round 4. load_combined_domain
//!  walks the sibling ../miette repo as an additional bluebook root at depth 1.
//!  Miette's self/mind/body/library/surface aggregates physically live in
//!  chrisyoung/miette post-split ; the runtime needs to find them for the same
//!  dispatch domain that scans hecks_conception/aggregates/. The pre-push
//!  behaviors gate (tooling/git-hooks/pre-push) has scanned this root for
//!  weeks ; the runtime now matches. Skipped silently when the sibling repo
//!  isn't checked out (CI running on hecks alone keeps working). Retires
//!  alongside the broader i118 hecks/miette reshape.]

use storehouse::{parser, validator, validator_warnings, server, conceiver, heki, heki_query, dump,
                 behaviors_parser, behaviors_dump};
use storehouse::runtime::Runtime;
use storehouse::corpus_loader::load_combined_domain;
use storehouse::story_runtime::{story_sorted_steps, story_args_to_tokens};

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

    // StoreHouse generic dispatcher (i484 surface). Three verbs that
    // honour the contract declared in hecks_conception/storehouse/
    // {lexicon,dispatch,query}.bluebook + companion .hecksagons :
    //
    //   storehouse storehouse route <phrase> [k=v ...]
    //     — Dispatch.Route. Walks the conception, locates the bluebook
    //       declaring the phrase's Aggregate.Command, invokes it via
    //       run::run_script with `entrypoint=<phrase>`. The chain
    //       (Lookup → bind → Invoke) lives here imperatively today ;
    //       i493 grows the runtime so the storehouse bluebooks become
    //       self-evidencing (bind directive, dotted templates, cross-
    //       aggregate auto-dispatch). When that lands, this shim
    //       retires through the same path.
    //
    //   storehouse storehouse compile [conception_root]
    //     — Lexicon.Compile. Walks bluebooks, writes lexicon.heki rows
    //       (one per phrase + a singleton row carrying CompiledAt +
    //       PhraseCount). Idempotent.
    //
    //   storehouse storehouse read <Aggregate.attribute>
    //     — Query.Read. Resolves heki path via heki::path_for_lookup,
    //       projects the named attribute from the latest record,
    //       prints the flattened value.
    //
    //   storehouse storehouse list [filter]
    //     — Lexicon.List. Recompiles if stale (mtime check), prints
    //       the matching phrases.
    //
    //   storehouse storehouse lookup <phrase>
    //     — Lexicon.Lookup. Recompiles if stale, prints the resolved
    //       target as JSON ({phrase, bluebook_path, aggregate, command}).
    if command == "storehouse" {
        std::process::exit(run_storehouse(&args));
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
        eprintln!("  storehouse aggregates/ Aggregate.Command");
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
        storehouse::behaviors_conceiver::commands::run_conceive_behaviors(&args);
        return;
    }

    if command == "behaviors" {
        // i500 — alias for `test`. Stays one release, then collapses.
        run_behaviors(&args);
        return;
    }

    if command == "test" {
        // i500 — universal `.behaviors` runner. CLI glue around the
        // existing run_suite_with_domain / run_suite_with_fixtures
        // engine. File OR directory, filter/aggregate/format flags,
        // structured exit codes (0/1/2/3).
        std::process::exit(run_test(&args));
    }

    if command == "dump-fixtures" {
        let path = args.get(2).expect("usage: storehouse dump-fixtures <file.fixtures>");
        let source = std::fs::read_to_string(path).expect("cannot read");
        let file = storehouse::fixtures_parser::parse(&source);
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
        let path = args.get(2).expect("usage: storehouse dump-world <file.world>");
        let source = std::fs::read_to_string(path).expect("cannot read");
        let world = storehouse::world::parser::parse(&source);
        println!("{}", serde_json::to_string_pretty(&dump_world_json(&world)).unwrap());
        return;
    }

    if command == "dump-hecksagon" {
        let path = args.get(2).expect("usage: storehouse dump-hecksagon <file.hecksagon>");
        let source = std::fs::read_to_string(path).expect("cannot read");
        let hex = storehouse::hecksagon_parser::parse(&source);
        println!("{}", serde_json::to_string_pretty(&dump_hecksagon_json(&hex)).unwrap());
        return;
    }

    // `storehouse project terraform <hecksagon> [world] [--output <dir>]`
    //
    // Hecksagon → Terraform HCL projection (i693 Phase 1). Reads the
    // .hecksagon, optionally reads the .world, walks every named
    // adapter, looks up its kind in the AdapterKindMapping table
    // (storehouse::projection::terraform::mappings), and emits one
    // `resource` block per adapter that maps to a known resource type.
    // Adapters with no mapping (:memory, :tts, :llm, :shell, :exec,
    // :env, :fs, :stdin/out/err, :compute, :web_tool) are silently
    // skipped — they are runtime-side, not cloud-side.
    //
    // --output <dir> writes main.tf into the directory (creating it
    // if missing) ; without --output the HCL is written to stdout so
    // the projection can be piped into `terraform fmt -` or diffed
    // against goldens.
    //
    // Bluebook contract :
    //   hecks_conception/aggregates/framework/projection/terraform.bluebook
    //
    // The CLI is the thin file-I/O boundary ; the projection itself
    // is a pure walk over IR (storehouse::projection::terraform).
    if command == "project" {
        std::process::exit(run_project(&args));
    }

    if command == "specialize" {
        run_specialize(&args);
        return;
    }

    if command == "cascade" {
        let path = args.get(2).expect("usage: storehouse cascade <bluebook>");
        let source = std::fs::read_to_string(path).expect("cannot read");
        let domain = storehouse::parser::parse(&source);
        for agg in &domain.aggregates {
            for cmd in &agg.commands {
                let events = storehouse::cascade::cascade_emits(&domain, &cmd.name);
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

    // `storehouse run <file.bluebook> [key=val ...]`
    //
    // Script-mode execution: strip shebang, parse .bluebook + companion
    // .hecksagon, wire adapters, dispatch `entrypoint` with argv-bound
    // attrs. Exits 0/1/2/3/4 per storehouse::run::ExitKind.
    //
    // The legacy interactive REPL that used to live under `run` now
    // lives under `storehouse repl <file>` (below).
    if command == "run" {
        std::process::exit(storehouse::run::run_script(&args));
    }

    // `storehouse loop <agg-dir-or-bluebook> <Aggregate.Command> --every <duration> [key=val ...]`
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

    // `storehouse run-loop <bluebook-tree> [--every <dur>] [--emit <Event:Type:Id>]
    //   [--dispatch <Aggregate.Command> [--with k=v ...]]`
    //
    // PM loop driver — long-running runtime daemon. Boots once, ticks
    // at the configured cadence, fires registered events / commands
    // into the runtime so PMs (sleep_cycle, dream, mind, ...) advance
    // their state continuously instead of one-shot per shell invocation.
    //
    // Substrate for retiring `mindstream.sh` : that shell exists because
    // no Rust scheduler does. With run-loop the cadence becomes Rust
    // and the bluebook-declared PMs react to each tick's events through
    // the same pm_engine + drain_policies machinery the one-shot
    // dispatch path already uses.
    //
    // Today the cadence + actions are passed via CLI flags ; once
    // block_grammar (i218) lifts the `cadence ... every Xs` keyword
    // into Rust IR, run-loop reads them from the parsed Domain and
    // mindstream.sh retires entirely. This subcommand IS the
    // long-running substrate that lift requires.
    if command == "run-loop" {
        run_pm_loop(&args);
        return;
    }

    // `storehouse daemon <ensure|status|stop> <pidfile> [command...]`
    //
    // Process-lifecycle primitive — the runtime gap that kept boot_miette
    // in shell. `ensure <pidfile> <cmd> [args]` reads the pidfile, returns
    // alive if the PID is still running (idempotent boot), otherwise spawns
    // the command detached (setsid + null stdio) and writes the new PID.
    // No wrapping subshells, no PPID=1 orphan launchers — the leak that
    // accumulated five ghost shells over today's session is structurally
    // closed. Sibling of the cadence-loop primitive (`storehouse loop`) ;
    // together they let bluebook capabilities declare daemon lifecycles
    // without reaching for shell. boot_miette.sh's `( cd "$DIR" && nohup
    // ./script & )` pattern retires once it migrates to this primitive.
    if command == "daemon" {
        run_daemon(&args);
        return;
    }

    // `storehouse macrophage` — PostToolUse listener primitive.
    // (Old name `storehouse enforce-edit` kept as deprecated alias.)
    //
    // Reads tool-input JSON from stdin, classifies the touched file
    // by extension, dispatches Macrophage.RecordXxxEdit (and, for
    // imperative-language files, Macrophage.Complain), prints the
    // complaint to stderr, exits 2 so Claude Code routes the
    // complaint to the agent as a system reminder.
    //
    // Closes the runtime gap (i104) that previously forced
    // enforce_bluebook.sh to exist — Claude Code's PostToolUse hook
    // contract takes a command, and the command can now be storehouse
    // directly. No shell glue. Same family as `storehouse loop` and
    // `storehouse daemon` — kernel-surface primitives a bluebook
    // capability dispatches into. The Macrophage brain stays in
    // aggregates/discipline/macrophage/macrophage.bluebook (i553).
    if command == "enforce-edit" || command == "macrophage" {
        // Deprecation notice if old form used. Print BEFORE the dispatch
        // because run_macrophage exits internally (never returns).
        if command == "enforce-edit" {
            eprintln!("[macrophage] note : `storehouse enforce-edit` renamed to `storehouse macrophage` (i553) ; old form still works for now.");
        }
        run_macrophage(&args);
        return;
    }

    // `storehouse statusline` — Statusline capability runner (i97
    // → i145). Fires the bluebook-declared rendering of Miette's
    // one-line body status. Replaces statusline-command.sh's 273-
    // line shell with a Rust mirror of run_status/ : reads body
    // heki, branches on consciousness state, prints a single line.
    // Same family as run_status / run_loop / run_daemon — kernel-
    // surface CLI primitive a bluebook capability dispatches into.
    // Bluebook brain stays in capabilities/statusline/.
    if command == "statusline" {
        storehouse::run_statusline::run();
        return;
    }

    // `storehouse follow [stream]` — tail the storehouse bus log
    // from another terminal. Reads the same file the runtime's
    // `storehouse_log` writer appends to (default
    // `<miette-state>/information/storehouse.log` or whatever
    // `$STOREHOUSE_LOG_FILE` overrides it to). Filter forms : `all`
    // (default), `dispatch` / `event` / `cascade` / `policy` for one
    // of the four surfaces, or any other substring for a contains-
    // match (e.g. `follow ShellTool`, `follow Tools::EmailTool`).
    // Polls every 100 ms ; SIGINT exits cleanly. Same kernel-surface
    // family as `storehouse statusline` — paired with the
    // `runtime::storehouse_log` writer that lives in i622.
    if command == "follow" {
        std::process::exit(storehouse::run_follow::run(&args));
    }

    // `storehouse serve-stdio <agg-dir>` — warm, resident dispatch
    // server over stdin/stdout. The second half of the speed plan :
    // the first half (lazy repository hydration) cut a COLD single-shot
    // dispatch from ~5.3s → ~660ms ; this pays that ~660ms boot ONCE
    // and answers every subsequent dispatch in single-digit ms.
    //
    // Distinct name from the HTTP `serve <dir> [port]` arm below
    // (server::multi::serve_directory) — that one is unchanged.
    //
    // Boots EXACTLY like dispatch_hecksagon (load_combined_domain +
    // load_all_hecksagons + Runtime::boot_with_hecksagons +
    // register_llm_providers) so warm dispatches produce byte-identical
    // .heki to the cold one-shot path, then loops in
    // storehouse::run_serve. Per-dispatch freshness (touched repos
    // re-read from .heki) lives in the loop ; the MCP child speaks the
    // sentinel-line protocol back. See run_serve/mod.rs.
    if command == "serve-stdio" {
        run_serve_stdio(path);
        return;
    }

    // `storehouse serve-socket <agg-dir> [socket-path]` — warm,
    // resident dispatch server over a UNIX DOMAIN SOCKET. Same boot +
    // dispatch body as serve-stdio (byte-identical .heki) ; the only
    // difference is the transport. This is the form that lives as an
    // overmind DAEMON (body) : the warm runtime is independent of
    // Claude, so a Claude restart rebuilds only the MCP membrane while
    // this daemon stays warm. The MCP becomes a thin socket CLIENT
    // (connect → write request line → read result line). If no
    // socket-path is given, the daemon binds the deterministic
    // per-root path the MCP client also computes (see
    // run_serve::sock_path_for_root). See run_serve/socket.rs.
    if command == "serve-socket" {
        let sock_arg = args.get(3).map(|s| s.as_str());
        run_serve_socket(path, sock_arg);
        return;
    }

    // `storehouse sock-path <agg-dir>` — print the deterministic unix
    // socket path the serve-socket daemon binds for that root, then
    // exit. ONE source of truth for the address : the MCP socket client
    // shells this once per root (the JS side can't reproduce Rust's
    // SipHash DefaultHasher) and caches the answer, so daemon + client
    // agree without coordination. Pure path derivation — no boot.
    if command == "sock-path" {
        if path.is_empty() {
            eprintln!("usage: storehouse sock-path <aggregates-dir>");
            std::process::exit(2);
        }
        println!("{}", storehouse::run_serve::sock_path_for_root(path).display());
        return;
    }

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

    // `storehouse clock <agg-dir> --segment <hour-range>:<Cmd> [...] [--poll <dur>]`
    //
    // Wall-clock segment trigger primitive (i107). Boots the runtime
    // once, then on each poll tick (default 60s) computes the current
    // local-hour segment and dispatches the matching command IFF the
    // segment changed since the last tick. Replaces circadian.sh.
    //
    // Same family as `storehouse loop` and `storehouse daemon` —
    // kernel-surface primitive a bluebook circadian capability
    // dispatches into. Same i80 retirement contract.
    if command == "clock" {
        run_clock(&args);
        return;
    }

    // `storehouse sleep` — blocking streaming-sleep CLI (i113).
    //
    // Dispatches Consciousness.EnterSleep (skipping if state is already
    // "sleeping" — mid-flight join), then polls consciousness.heki /
    // dream_state.heki / lucid_dream.heki at 1Hz, emitting one streaming
    // line per state change. Breaks when state != "sleeping", waits
    // briefly for /tmp/wake_review_latest.md (the wake hook fires
    // wake_review.sh + interpret_dream.sh automatically), prints it to
    // stdout, exits 0.
    //
    // Same family as run_loop / run_daemon / run_macrophage / run_clock
    // — kernel-surface CLI primitive. Bluebook brain (sleep.bluebook,
    // lucid_dream.bluebook) stays unchanged ; this just wires the
    // dispatch + heki polling + dream stream + wake-report read into a
    // single blocking command.
    if command == "sleep" {
        run_sleep(&args);
        return;
    }

    // `storehouse repl <file.bluebook>` — interactive REPL. Same shape
    // as the pre-PR `run` command so any script that relied on that
    // behavior moves to `repl`.
    if command == "repl" {
        let repl_path = args.get(2).unwrap_or_else(|| {
            eprintln!("Usage: storehouse repl <file.bluebook>");
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

    // `storehouse query <root-or-bluebook> <Domain::Aggregate.snake> [k=v]`
    // Route through dispatch_hecksagon, which is FQN-query-aware and reads
    // from the same data dir the matching dispatch wrote to. Without this
    // the query subcommand fell through to the single-file read path below
    // and died on a directory root ("Is a directory").
    if command == "query" {
        let root = path;
        let verb = args.get(3).cloned().unwrap_or_default();
        if verb.is_empty() {
            eprintln!("Usage: storehouse query <root-or-bluebook> <Domain::Aggregate.snake_case> [k=v ...]");
            std::process::exit(1);
        }
        let attrs: std::collections::HashMap<String, serde_json::Value> = args.get(4..)
            .unwrap_or(&[]).iter()
            .filter_map(|a| {
                let mut parts = a.splitn(2, '=');
                let key = parts.next()?;
                let val = parts.next()?;
                Some((key.to_string(), serde_json::Value::String(val.to_string())))
            })
            .collect();
        dispatch_hecksagon(root, &verb, attrs);
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
        // `project` is now its own subcommand (i693 Phase 1) — dispatched
        // earlier in main(), handled by run_project. The legacy
        // "project is now: storehouse serve …" deprecation message was
        // retired when the keyword was repurposed for hecksagon →
        // Terraform HCL projection.
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
        match storehouse::runtime::seed_loader::load(rt, path) {
            Ok(count) => eprintln!("  loaded {} seed commands from {}", count, path),
            Err(e) => eprintln!("  seed error: {}", e),
        }
    }
}

/// `storehouse behaviors path/to/X_behavioral_tests.bluebook`
///
/// Loads the matching source bluebook (suffix-stripped: pizzas_behavioral_tests
/// → pizzas), runs every test through Runtime::boot in pure-memory mode,
/// prints PASS/FAIL per test plus a summary, exits non-zero on any failure.
///
/// Pure memory by construction — Runtime::boot has no data_dir, no
/// hecksagon, no adapters. If a test triggers IO, the source bluebook
/// is the thing to fix.
/// Walk up from a .behaviors path looking for an "aggregates"
/// directory ancestor. Returns the path to that aggregates dir
/// (suitable for `load_combined_domain`) or None when invoked
/// outside a conception layout (programmatic invocation, standalone
/// test fixtures, etc.). Used by `run_behaviors` to opt into the
/// full-domain path when the file lives in a recognizable corpus.
fn behaviors_aggregates_root(suite_path: &str) -> Option<String> {
    let abs = std::fs::canonicalize(suite_path).ok()?;
    let mut cur = abs.parent()?.to_path_buf();
    for _ in 0..6 {
        if cur.file_name().map(|n| n == "aggregates").unwrap_or(false) {
            return Some(cur.to_string_lossy().into_owned());
        }
        // also recognize tree shapes where the .behaviors lives under
        // capabilities/ — load_combined_domain walks both at once via
        // the sibling-capability path.
        let agg_sibling = cur.join("aggregates");
        if agg_sibling.is_dir() {
            return Some(agg_sibling.to_string_lossy().into_owned());
        }
        // i117 Round 4 — when the .behaviors lives under the sibling
        // miette/ repo (e.g. miette/self/identity/being.behaviors),
        // the canonical aggregates root is hecks/hecks_conception/aggregates.
        // Walk to a sibling hecks/hecks_conception/aggregates and return
        // that ; load_combined_domain's i117 sibling-walk picks the
        // miette/ root back up, so the cross-corpus dispatch works.
        let sibling_hecks_aggs = cur.join("hecks/hecks_conception/aggregates");
        if sibling_hecks_aggs.is_dir() {
            return Some(sibling_hecks_aggs.to_string_lossy().into_owned());
        }
        // i118 Round 3 (capabilities reorg) — when the .behaviors lives
        // under one of the new bucket dirs at the hecks repo root
        // (runtime/, discipline/, cli/, integrations/, tools/), the
        // canonical aggregates root is the same repo's
        // hecks_conception/aggregates. Walk to it directly. Without
        // this, behaviors tests on lifted caps fall to single-file
        // domain (cross_cascade tests can`t fire policy chains that
        // hop into sibling bluebooks).
        let inner_hecks_aggs = cur.join("hecks_conception/aggregates");
        if inner_hecks_aggs.is_dir() {
            return Some(inner_hecks_aggs.to_string_lossy().into_owned());
        }
        if !cur.pop() { break; }
    }
    None
}

fn run_behaviors(args: &[String]) {
    let suite_path = args.get(2).unwrap_or_else(|| {
        eprintln!("Usage: storehouse behaviors <X_behavioral_tests.bluebook>");
        std::process::exit(1);
    });
    let source_path = source_for_suite(suite_path);
    let suite_text = std::fs::read_to_string(suite_path).unwrap_or_else(|e| {
        eprintln!("Cannot read {}: {}", suite_path, e); std::process::exit(1);
    });
    let source_text = std::fs::read_to_string(&source_path).unwrap_or_else(|e| {
        eprintln!("Cannot read source {}: {}", source_path, e); std::process::exit(1);
    });
    if !storehouse::behaviors_parser::is_behaviors_source(&suite_text) {
        eprintln!("{} is not a Hecks.behaviors file", suite_path);
        std::process::exit(1);
    }
    let suite = storehouse::behaviors_parser::parse(&suite_text);

    // Auto-load sibling .fixtures if present (i4 gap 8). Cross-aggregate
    // cascades that read state seeded by another aggregate's fixtures no
    // longer need explicit setup chains in every test.
    let fixtures_path = storehouse::behaviors_fixtures::locate_path(suite_path);
    let fixtures = fixtures_path.as_deref()
        .and_then(storehouse::behaviors_fixtures::parse_file);

    println!("Running {} test(s) from {}", suite.tests.len(), suite_path);
    println!("  source: {}", source_path);
    if let Some(ref fp) = fixtures_path {
        println!("  fixtures: {}", fp);
    }
    println!();

    // i112 cleanup — always load the combined domain when the .behaviors
    // file lives under a recognizable aggregates tree. The runner picks
    // per-test which domain to use : `kind: :cross_cascade` tests run
    // against the combined domain so cross-bluebook policy chains fire
    // end-to-end ; all other tests run isolated against the source
    // bluebook only. Tests with strict emit-list assertions stay strict ;
    // cross-cascade tests opt in via the kind flag.
    let combined = behaviors_aggregates_root(suite_path)
        .map(|root| load_combined_domain(&root));
    let result = match combined.as_ref() {
        Some(d) => storehouse::behaviors_runner::run_suite_with_domain(
            &source_text, d, &suite, fixtures.as_ref(),
        ),
        None    => storehouse::behaviors_runner::run_suite_with_fixtures(
            &source_text, &suite, fixtures.as_ref(),
        ),
    };
    for run in &result.runs {
        let icon = match run.status {
            storehouse::behaviors_runner::TestStatus::Pass  => "✓",
            storehouse::behaviors_runner::TestStatus::Fail  => "✗",
            storehouse::behaviors_runner::TestStatus::Error => "⚠",
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

// ============================================================
// i500 — `storehouse test <path>` subcommand.
//
// CLI glue around the behaviors_runner engine. File OR directory,
// filter/aggregate flags, output formats (compact/tap/rspec/json),
// structured exit codes :
//   0  all pass
//   1  ≥1 fail/error
//   2  parse error
//   3  no tests matched filter (suppress via --allow-empty)
//
// The legacy `behaviors` subcommand stays as alias for one release.
// ============================================================

#[derive(Clone, Copy, PartialEq)]
enum TestFmt { Compact, Tap, Rspec, Json }

struct TestOpts {
    path: String,
    filter: Option<String>,
    aggregate: Option<String>,
    fmt: TestFmt,
    fail_fast: bool,
    list: bool,
    corpus: Option<String>,
    allow_empty: bool,
}

fn parse_test_opts(args: &[String]) -> Result<TestOpts, String> {
    let mut path: Option<String> = None;
    let mut filter: Option<String> = None;
    let mut aggregate: Option<String> = None;
    let mut fmt = TestFmt::Compact;
    let mut fail_fast = false;
    let mut list = false;
    let mut corpus: Option<String> = None;
    let mut allow_empty = false;
    let mut i = 2;
    while i < args.len() {
        let a = args[i].as_str();
        match a {
            "--filter"      => { i += 1; filter = Some(args.get(i).cloned().ok_or("--filter needs a value")?); }
            "--aggregate"   => { i += 1; aggregate = Some(args.get(i).cloned().ok_or("--aggregate needs a value")?); }
            "--format"      => {
                i += 1;
                let v = args.get(i).map(|s| s.as_str()).unwrap_or("");
                fmt = match v {
                    "compact" => TestFmt::Compact,
                    "tap"     => TestFmt::Tap,
                    "rspec"   => TestFmt::Rspec,
                    "json"    => TestFmt::Json,
                    other     => return Err(format!("--format expects compact|tap|rspec|json, got `{}`", other)),
                };
            }
            "--fail-fast"   => fail_fast = true,
            "--list"        => list = true,
            "--corpus"      => { i += 1; corpus = Some(args.get(i).cloned().ok_or("--corpus needs a value")?); }
            "--allow-empty" => allow_empty = true,
            other if other.starts_with("--") => return Err(format!("unknown flag: {}", other)),
            other => {
                if path.is_none() { path = Some(other.to_string()); }
                else { return Err(format!("unexpected positional arg: {}", other)); }
            }
        }
        i += 1;
    }
    let path = path.unwrap_or_else(|| {
        // Default to $PWD/hecks_conception or $PWD per i500.
        let cwd = std::env::current_dir().ok()
            .and_then(|p| Some(p.to_string_lossy().into_owned()))
            .unwrap_or_else(|| ".".into());
        let candidate = format!("{}/hecks_conception", cwd);
        if std::path::Path::new(&candidate).is_dir() { candidate } else { cwd }
    });
    Ok(TestOpts { path, filter, aggregate, fmt, fail_fast, list, corpus, allow_empty })
}

fn collect_behavior_files(root: &str) -> Vec<String> {
    let p = std::path::Path::new(root);
    if p.is_file() {
        return vec![root.to_string()];
    }
    let mut out: Vec<String> = Vec::new();
    let mut stack: Vec<std::path::PathBuf> = vec![p.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let entries = match std::fs::read_dir(&dir) { Ok(e) => e, Err(_) => continue };
        let mut sub: Vec<std::path::PathBuf> = Vec::new();
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                // Skip hidden/.git dirs ; conventional vendor / build trees.
                if let Some(name) = path.file_name().and_then(|n| n.to_str()) {
                    if name.starts_with('.') || name == "node_modules" || name == "target" { continue; }
                }
                sub.push(path);
            } else if path.is_file() && path.extension().and_then(|s| s.to_str()) == Some("behaviors") {
                out.push(path.to_string_lossy().into_owned());
            }
        }
        // Stable, source order : sort entries lexically.
        sub.sort();
        for s in sub.into_iter().rev() { stack.push(s); }
    }
    out.sort();
    out
}

struct SuiteRunReport {
    suite_path: String,
    source_path: String,
    fixtures_path: Option<String>,
    parse_error: Option<String>,
    runs: Vec<storehouse::behaviors_runner::TestRun>,
    skipped_by_filter: usize,
}

fn run_one_suite(suite_path: &str, opts: &TestOpts) -> SuiteRunReport {
    let source_path = source_for_suite(suite_path);
    let mut report = SuiteRunReport {
        suite_path: suite_path.to_string(),
        source_path: source_path.clone(),
        fixtures_path: None,
        parse_error: None,
        runs: Vec::new(),
        skipped_by_filter: 0,
    };
    let suite_text = match std::fs::read_to_string(suite_path) {
        Ok(t) => t,
        Err(e) => { report.parse_error = Some(format!("cannot read {}: {}", suite_path, e)); return report; }
    };
    if !storehouse::behaviors_parser::is_behaviors_source(&suite_text) {
        report.parse_error = Some(format!("{} is not a Hecks.behaviors file", suite_path));
        return report;
    }
    let source_text = match std::fs::read_to_string(&source_path) {
        Ok(t) => t,
        Err(e) => { report.parse_error = Some(format!("cannot read source {}: {}", source_path, e)); return report; }
    };

    let mut suite = storehouse::behaviors_parser::parse(&suite_text);

    // Apply --filter / --aggregate post-parse. We mutate suite.tests in
    // place ; the runner doesn't care that it was filtered.
    let original_count = suite.tests.len();
    let filter_lc = opts.filter.as_ref().map(|s| s.to_lowercase());
    let agg_match = opts.aggregate.as_ref();
    suite.tests.retain(|t| {
        if let Some(ref f) = filter_lc {
            if !t.description.to_lowercase().contains(f) { return false; }
        }
        if let Some(a) = agg_match {
            if &t.on_aggregate != a { return false; }
        }
        true
    });
    report.skipped_by_filter = original_count - suite.tests.len();

    if suite.tests.is_empty() {
        return report;
    }

    let fixtures_path = storehouse::behaviors_fixtures::locate_path(suite_path);
    let fixtures = fixtures_path.as_deref()
        .and_then(storehouse::behaviors_fixtures::parse_file);
    report.fixtures_path = fixtures_path;

    // --corpus override falls back to the auto-detect when absent.
    let combined = match &opts.corpus {
        Some(root) => Some(load_combined_domain(root)),
        None => behaviors_aggregates_root(suite_path).map(|root| load_combined_domain(&root)),
    };
    let result = match combined.as_ref() {
        Some(d) => storehouse::behaviors_runner::run_suite_with_domain(
            &source_text, d, &suite, fixtures.as_ref(),
        ),
        None => storehouse::behaviors_runner::run_suite_with_fixtures(
            &source_text, &suite, fixtures.as_ref(),
        ),
    };
    report.runs = result.runs;
    report
}

fn run_test(args: &[String]) -> i32 {
    let opts = match parse_test_opts(args) {
        Ok(o) => o,
        Err(e) => { eprintln!("test: {}", e); return 2; }
    };

    let files = collect_behavior_files(&opts.path);
    if files.is_empty() {
        if opts.allow_empty { return 0; }
        eprintln!("test: no .behaviors files found at {}", opts.path);
        return 3;
    }

    // --list : print the plan and exit 0. Useful for ratchet counts.
    if opts.list {
        let mut total = 0usize;
        for f in &files {
            let text = match std::fs::read_to_string(f) {
                Ok(t) => t, Err(_) => continue,
            };
            if !storehouse::behaviors_parser::is_behaviors_source(&text) { continue; }
            let suite = storehouse::behaviors_parser::parse(&text);
            for t in &suite.tests {
                let filter_ok = match &opts.filter {
                    Some(s) => t.description.to_lowercase().contains(&s.to_lowercase()),
                    None => true,
                };
                let agg_ok = match &opts.aggregate {
                    Some(a) => &t.on_aggregate == a,
                    None => true,
                };
                if filter_ok && agg_ok {
                    println!("{}\t{}\t{}\t{}", f, t.on_aggregate, t.kind, t.description);
                    total += 1;
                }
            }
        }
        println!("# {} test(s) planned", total);
        return 0;
    }

    let mut reports: Vec<SuiteRunReport> = Vec::new();
    let mut had_failure = false;
    let mut had_parse_error = false;

    for f in &files {
        let report = run_one_suite(f, &opts);
        if report.parse_error.is_some() { had_parse_error = true; }
        let suite_failed = report.runs.iter().any(|r|
            r.status != storehouse::behaviors_runner::TestStatus::Pass);
        if suite_failed { had_failure = true; }

        match opts.fmt {
            TestFmt::Compact => render_compact_inline(&report),
            TestFmt::Rspec   => render_rspec_inline(&report),
            TestFmt::Tap     => {} // emitted in batch below for stable numbering
            TestFmt::Json    => {} // emitted as a single JSON document below
        }

        reports.push(report);

        if opts.fail_fast && (had_failure || had_parse_error) { break; }
    }

    let total_runs: usize = reports.iter().map(|r| r.runs.len()).sum();
    let total_pass: usize = reports.iter().map(|r| r.runs.iter().filter(|x|
        x.status == storehouse::behaviors_runner::TestStatus::Pass).count()).sum();
    let total_fail: usize = reports.iter().map(|r| r.runs.iter().filter(|x|
        x.status == storehouse::behaviors_runner::TestStatus::Fail).count()).sum();
    let total_err:  usize = reports.iter().map(|r| r.runs.iter().filter(|x|
        x.status == storehouse::behaviors_runner::TestStatus::Error).count()).sum();
    let total_filtered: usize = reports.iter().map(|r| r.skipped_by_filter).sum();

    match opts.fmt {
        TestFmt::Compact => {
            println!();
            println!("{} file(s) ; {} test(s) : {} passed, {} failed, {} errored",
                     reports.len(), total_runs, total_pass, total_fail, total_err);
            if total_filtered > 0 {
                println!("  ({} skipped by filter)", total_filtered);
            }
        }
        TestFmt::Rspec => {
            println!();
            for r in &reports {
                if let Some(err) = &r.parse_error {
                    println!("PARSE ERROR — {}: {}", r.suite_path, err);
                }
                for run in &r.runs {
                    if run.status != storehouse::behaviors_runner::TestStatus::Pass {
                        let kind = match run.status {
                            storehouse::behaviors_runner::TestStatus::Fail => "FAILED",
                            storehouse::behaviors_runner::TestStatus::Error => "ERROR",
                            _ => "",
                        };
                        println!("  {} — {}", kind, run.description);
                        if let Some(m) = &run.message { println!("    {}", m); }
                    }
                }
            }
            println!("\n{} examples, {} failures, {} errors", total_runs, total_fail, total_err);
        }
        TestFmt::Tap => {
            println!("TAP version 13");
            println!("1..{}", total_runs);
            let mut n = 0usize;
            for r in &reports {
                if let Some(err) = &r.parse_error {
                    println!("# parse error in {}: {}", r.suite_path, err);
                    continue;
                }
                for run in &r.runs {
                    n += 1;
                    let prefix = match run.status {
                        storehouse::behaviors_runner::TestStatus::Pass  => "ok",
                        storehouse::behaviors_runner::TestStatus::Fail  => "not ok",
                        storehouse::behaviors_runner::TestStatus::Error => "not ok",
                    };
                    println!("{} {} - {}", prefix, n, run.description);
                    if let Some(msg) = &run.message {
                        println!("  ---");
                        for line in msg.lines() { println!("  {}", line); }
                        println!("  ---");
                    }
                }
            }
            println!("# {} passed, {} failed, {} errored", total_pass, total_fail, total_err);
        }
        TestFmt::Json => {
            let payload = serde_json::json!({
                "files": reports.iter().map(|r| {
                    serde_json::json!({
                        "suite": r.suite_path,
                        "source": r.source_path,
                        "fixtures": r.fixtures_path,
                        "parse_error": r.parse_error,
                        "skipped_by_filter": r.skipped_by_filter,
                        "runs": r.runs.iter().map(|run| {
                            let status = match run.status {
                                storehouse::behaviors_runner::TestStatus::Pass  => "pass",
                                storehouse::behaviors_runner::TestStatus::Fail  => "fail",
                                storehouse::behaviors_runner::TestStatus::Error => "error",
                            };
                            serde_json::json!({
                                "description": run.description,
                                "status": status,
                                "message": run.message,
                            })
                        }).collect::<Vec<_>>(),
                    })
                }).collect::<Vec<_>>(),
                "summary": {
                    "files": reports.len(),
                    "total": total_runs,
                    "passed": total_pass,
                    "failed": total_fail,
                    "errored": total_err,
                    "filtered": total_filtered,
                }
            });
            println!("{}", serde_json::to_string_pretty(&payload).unwrap());
        }
    }

    // Empty-match handling : applies after parse + filter. If everything
    // got filtered out across all suites, that's exit 3 unless allowed.
    if total_runs == 0 && !had_parse_error {
        if opts.allow_empty { return 0; }
        eprintln!("test: no tests matched filter (use --allow-empty to suppress)");
        return 3;
    }

    if had_parse_error { return 2; }
    if had_failure { return 1; }
    0
}

fn render_compact_inline(r: &SuiteRunReport) {
    if let Some(err) = &r.parse_error {
        println!("PARSE ERROR — {}: {}", r.suite_path, err);
        return;
    }
    println!("Running {} test(s) from {}", r.runs.len(), r.suite_path);
    println!("  source: {}", r.source_path);
    if let Some(fp) = &r.fixtures_path { println!("  fixtures: {}", fp); }
    for run in &r.runs {
        let icon = match run.status {
            storehouse::behaviors_runner::TestStatus::Pass  => "PASS",
            storehouse::behaviors_runner::TestStatus::Fail  => "FAIL",
            storehouse::behaviors_runner::TestStatus::Error => "ERR ",
        };
        println!("  {} {}", icon, run.description);
        if let Some(msg) = &run.message { println!("       {}", msg); }
    }
}

fn render_rspec_inline(r: &SuiteRunReport) {
    if r.parse_error.is_some() {
        print!("E"); use std::io::Write; let _ = std::io::stdout().flush();
        return;
    }
    use std::io::Write;
    for run in &r.runs {
        let c = match run.status {
            storehouse::behaviors_runner::TestStatus::Pass  => '.',
            storehouse::behaviors_runner::TestStatus::Fail  => 'F',
            storehouse::behaviors_runner::TestStatus::Error => 'E',
        };
        print!("{}", c);
    }
    let _ = std::io::stdout().flush();
}

/// `storehouse check-io <bluebook> [--strict]`
///
/// Asserts a bluebook is pure-memory-runnable. Two layers: static IR
/// scan for IO-suggestive patterns (advisory by default), and a
/// runtime smoke that boots Runtime::boot in pure-memory mode and
/// dispatches every command. Exit 0 when runtime smoke passes
/// (--strict promotes warnings to errors).
fn run_check_io(args: &[String]) {
    let path = args.get(2).unwrap_or_else(|| {
        eprintln!("Usage: storehouse check-io <bluebook> [--strict]");
        std::process::exit(1);
    });
    let strict = args.iter().any(|a| a == "--strict");

    let source = std::fs::read_to_string(path).unwrap_or_else(|e| {
        eprintln!("Cannot read {}: {}", path, e); std::process::exit(1);
    });
    let domain = storehouse::parser::parse(&source);
    if domain.aggregates.is_empty() {
        eprintln!("{} has no aggregates — nothing to validate", path);
        std::process::exit(1);
    }

    println!("Checking {} ({})", domain.name, path);

    let report = storehouse::io_validator::check(domain);

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

/// `storehouse check-lifecycle <bluebook> [--strict]`
///
/// Catches contradictory lifecycle declarations — transitions whose
/// `from:` state is unreachable, defaults that no transition can
/// exit, etc. Static IR walk; no runtime needed.
fn run_check_lifecycle(args: &[String]) {
    let path = args.get(2).unwrap_or_else(|| {
        eprintln!("Usage: storehouse check-lifecycle <bluebook> [--strict]");
        std::process::exit(1);
    });
    let strict = args.iter().any(|a| a == "--strict");

    let source = std::fs::read_to_string(path).unwrap_or_else(|e| {
        eprintln!("Cannot read {}: {}", path, e); std::process::exit(1);
    });
    let domain = storehouse::parser::parse(&source);
    if domain.aggregates.is_empty() {
        // i112 final — umbrella bluebooks (workflow + glossary, no
        // aggregates of their own) are valid : they orchestrate sibling
        // aggregates that live in their own bluebooks. A bluebook with
        // no aggregates has nothing to check at the lifecycle level —
        // exit 0 (not an error), so the pre-commit hook's per-file
        // sweep treats umbrellas the way they deserve.
        eprintln!("{} has no aggregates — nothing to check", path);
        std::process::exit(0);
    }

    println!("Checking {} ({})", domain.name, path);

    let report = storehouse::lifecycle_validator::check(&domain);
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

/// `storehouse check-duplicate-policies <bluebook>`
///
/// Refuses bluebooks that declare two or more policies sharing the
/// same `(on_event, trigger_command)` pair. Today those silently
/// coexist — the runtime fires every matching policy, so the trigger
/// command runs once per duplicate. Flat IR walk; no runtime needed.
fn run_check_duplicate_policies(args: &[String]) {
    let path = args.get(2).unwrap_or_else(|| {
        eprintln!("Usage: storehouse check-duplicate-policies <bluebook>");
        std::process::exit(1);
    });

    let source = std::fs::read_to_string(path).unwrap_or_else(|e| {
        eprintln!("Cannot read {}: {}", path, e); std::process::exit(1);
    });
    let domain = storehouse::parser::parse(&source);

    println!("Checking {} ({})", domain.name, path);

    let report = storehouse::duplicate_policy_validator::check(&domain);
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

/// `storehouse check-all <bluebook> [--strict]`
///
/// Run every validator in one go: lifecycle (unreachable transitions
/// + givens + mutation refs) and IO (declarative IO smells + pure-
/// memory dispatch smoke). Exits 0 only if both pass.
fn run_check_all(args: &[String]) {
    let path = args.get(2).unwrap_or_else(|| {
        eprintln!("Usage: storehouse check-all <bluebook> [--strict]");
        std::process::exit(1);
    });
    let strict = args.iter().any(|a| a == "--strict");

    let source = std::fs::read_to_string(path).unwrap_or_else(|e| {
        eprintln!("Cannot read {}: {}", path, e); std::process::exit(1);
    });
    let domain = storehouse::parser::parse(&source);
    if domain.aggregates.is_empty() {
        // i112 final — umbrella bluebooks (workflow + glossary, no
        // aggregates of their own) are valid : they orchestrate sibling
        // aggregates that live in their own bluebooks. A bluebook with
        // no aggregates has nothing to check at the lifecycle level —
        // exit 0 (not an error), so the pre-commit hook's per-file
        // sweep treats umbrellas the way they deserve.
        eprintln!("{} has no aggregates — nothing to check", path);
        std::process::exit(0);
    }

    println!("Checking {} ({})", domain.name, path);
    let mut overall_ok = true;

    // Lifecycle (borrows the domain — runs first).
    let lc = storehouse::lifecycle_validator::check(&domain);
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
    let io = storehouse::io_validator::check(domain);
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

/// `storehouse specialize <target> [--output PATH]`
///
/// `storehouse project <target> <hecksagon> [world] [--output <dir>]`
///
/// Hecksagon → cloud-infrastructure-as-code projection (i693 Phase 1).
/// Target name dispatches to the matching projector under
/// `storehouse::projection::`. Today only `terraform` is wired ; CDK,
/// CloudFormation, Pulumi, Kubernetes manifests join in Phase 2.
///
/// Reads the .hecksagon and optional .world, hands them to the
/// projector, and either writes <output>/main.tf or prints the
/// emitted HCL to stdout. Pure functional walk inside ; the CLI is
/// the thin file-I/O boundary.
///
/// Exit codes :
///   0 — projection succeeded
///   1 — file read / parse / write failed
///   2 — usage error (missing target, unknown target)
fn run_project(args: &[String]) -> i32 {
    let target = args.get(2).map(|s| s.as_str()).unwrap_or("");
    if target.is_empty() {
        eprintln!("Usage: storehouse project <target> <hecksagon> [world] [--output <dir>]");
        eprintln!("       targets: terraform");
        return 2;
    }
    if target != "terraform" {
        eprintln!("project: unknown target '{}' — only 'terraform' is wired (i693 Phase 1)", target);
        return 2;
    }
    let hecksagon_path = match args.get(3) {
        Some(p) => p.clone(),
        None => {
            eprintln!("project terraform: <hecksagon> path is required");
            return 2;
        }
    };
    // world is optional. If the 4th positional arg starts with --
    // it's a flag, not a world path.
    let world_path = args.get(4)
        .filter(|a| !a.starts_with("--"))
        .cloned();
    let output_dir = args.iter().position(|a| a == "--output")
        .and_then(|i| args.get(i + 1))
        .cloned();

    let hex_source = match std::fs::read_to_string(&hecksagon_path) {
        Ok(s) => s,
        Err(e) => { eprintln!("project: cannot read {}: {}", hecksagon_path, e); return 1; }
    };
    let hex = storehouse::hecksagon_parser::parse(&hex_source);

    let world_owned = match world_path.as_deref() {
        Some(p) => {
            let src = match std::fs::read_to_string(p) {
                Ok(s) => s,
                Err(e) => { eprintln!("project: cannot read {}: {}", p, e); return 1; }
            };
            Some(storehouse::world::parser::parse(&src))
        }
        None => None,
    };
    let result = storehouse::projection::terraform::project_hecksagon(
        &hex, world_owned.as_ref()
    );

    match output_dir {
        Some(dir) => {
            if let Err(e) = std::fs::create_dir_all(&dir) {
                eprintln!("project: cannot create {}: {}", dir, e);
                return 1;
            }
            let out_path = format!("{}/main.tf", dir.trim_end_matches('/'));
            if let Err(e) = std::fs::write(&out_path, &result.hcl) {
                eprintln!("project: cannot write {}: {}", out_path, e);
                return 1;
            }
            eprintln!("project terraform: wrote {} ({} resource(s))",
                      out_path, result.adapter_count);
        }
        None => {
            print!("{}", result.hcl);
            eprintln!("# {} resource(s) emitted", result.adapter_count);
        }
    }
    0
}

/// i51 Phase D pilot — Rust-native specializer driver. Mirrors
/// `bin/specialize <target>` on the Ruby side; both runtimes must
/// produce byte-identical output for every ported target until the
/// migration completes.
///
/// Target name (the first positional arg) dispatches to the matching
/// module under `storehouse::specializer::`. Writes to `--output
/// PATH` when provided, otherwise prints to stdout.
fn run_specialize(args: &[String]) {
    let target = args.get(2).map(|s| s.as_str()).unwrap_or("");
    if target.is_empty() {
        eprintln!("Usage: storehouse specialize <target> [--output PATH]");
        eprintln!("       storehouse specialize wasm_worker --app <app> --host <host> --auth-scheme <scheme> --auth-secret-env <env> --storehouse-path <path> [--output-dir <dir>]");
        eprintln!("       storehouse specialize cf_function_proxy --app <app> --worker-url-env <env> --auth-secret-env <env> [--auth-mode inject|enforce] [--allow-methods <json>] [--output <path>]");
        eprintln!("       storehouse specialize embedded_bluebooks --app <app> --root <path> --primary <basename> [--extensions <csv>] --output <path>");
        std::process::exit(2);
    }

    // wasm_worker + cf_function_proxy + embedded_bluebooks take their
    // own flag shapes : each emits files at app-relative paths derived
    // from per-deployment inputs (world-file values, project-root
    // walks) rather than a single tracked Rust file. Branch off before
    // the generic emit-target dispatch.
    if target == "wasm_worker" {
        run_specialize_wasm_worker(args);
        return;
    }
    if target == "cf_function_proxy" {
        run_specialize_cf_function_proxy(args);
        return;
    }
    if target == "embedded_bluebooks" {
        run_specialize_embedded_bluebooks(args);
        return;
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

    let rust = match storehouse::specializer::emit(target, &repo_root) {
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

/// `storehouse specialize wasm_worker --app <app> --host <host>
///   --auth-scheme <scheme> --auth-secret-env <env>
///   --storehouse-path <path> [--output-dir <dir>]`
///
/// Renders one app's WASM Cloudflare-Worker crate via the wasm_worker
/// specializer. Required flags : `--app`, `--host`, `--auth-scheme`,
/// `--auth-secret-env`, `--storehouse-path`. The `--auth-secret-env`
/// flag is allowed to be empty when `--auth-scheme` is `none`.
///
/// Output : writes `Cargo.toml` and `src/lib.rs` under `--output-dir`
/// (defaults to `./worker` relative to cwd). Emits nothing to stdout
/// on success ; the caller relies on the on-disk files.
///
/// Re-runs are idempotent — running the same command with the same
/// inputs against the same output-dir writes byte-identical files.
fn run_specialize_wasm_worker(args: &[String]) {
    fn flag(args: &[String], name: &str) -> Option<String> {
        args.iter()
            .position(|a| a == name)
            .and_then(|i| args.get(i + 1).cloned())
    }
    let app = match flag(args, "--app") {
        Some(v) if !v.is_empty() => v,
        _ => {
            eprintln!("specialize wasm_worker : missing --app <app>");
            std::process::exit(2);
        }
    };
    let host = flag(args, "--host").unwrap_or_else(|| "cf_worker".to_string());
    let auth_scheme = flag(args, "--auth-scheme").unwrap_or_else(|| "none".to_string());
    let auth_secret_env = flag(args, "--auth-secret-env").unwrap_or_default();
    let storehouse_path = match flag(args, "--storehouse-path") {
        Some(v) if !v.is_empty() => v,
        _ => {
            eprintln!("specialize wasm_worker : missing --storehouse-path <relative path to hecks/rust>");
            std::process::exit(2);
        }
    };
    let output_dir = flag(args, "--output-dir").unwrap_or_else(|| "./worker".to_string());

    // Validate scheme + secret combination — the shape's invariant
    // rejects empty auth_secret_env when scheme is anything other
    // than `none`. Surface here so the CLI fails loud rather than
    // emitting a lib.rs that reads from an empty env name.
    if auth_scheme != "none" && auth_secret_env.is_empty() {
        eprintln!(
            "specialize wasm_worker : --auth-secret-env is required when --auth-scheme is `{}` (only `none` allows it to be empty)",
            auth_scheme
        );
        std::process::exit(2);
    }

    let cargo = storehouse::specializer::wasm_worker::emit_cargo_toml(&app, &storehouse_path);
    let lib = storehouse::specializer::wasm_worker::emit_lib_rs(
        &app,
        &host,
        &auth_scheme,
        &auth_secret_env,
    );

    let out = std::path::PathBuf::from(&output_dir);
    let src_dir = out.join("src");
    if let Err(e) = std::fs::create_dir_all(&src_dir) {
        eprintln!("cannot create {}: {}", src_dir.display(), e);
        std::process::exit(1);
    }
    let cargo_path = out.join("Cargo.toml");
    let lib_path = src_dir.join("lib.rs");
    if let Err(e) = std::fs::write(&cargo_path, &cargo) {
        eprintln!("cannot write {}: {}", cargo_path.display(), e);
        std::process::exit(1);
    }
    if let Err(e) = std::fs::write(&lib_path, &lib) {
        eprintln!("cannot write {}: {}", lib_path.display(), e);
        std::process::exit(1);
    }

    eprintln!("wrote {} bytes to {}", cargo.len(), cargo_path.display());
    eprintln!("wrote {} bytes to {}", lib.len(), lib_path.display());
}

/// `storehouse specialize cf_function_proxy --app <app>
///   --worker-url-env <env> --auth-secret-env <env>
///   [--allow-methods <json>] [--output <path>]`
///
/// Renders one app's catch-all Cloudflare-Pages Function via the
/// cf_function_proxy specializer. Required flags : `--app`,
/// `--worker-url-env`, `--auth-secret-env`. Optional `--allow-methods`
/// is a JSON-array string (default `["GET","POST"]`) ; `--output`
/// is the file path to write (default `./functions/api/[[route]].js`).
///
/// Re-runs are idempotent — same inputs against the same output
/// path write byte-identical bytes.
fn run_specialize_cf_function_proxy(args: &[String]) {
    fn flag(args: &[String], name: &str) -> Option<String> {
        args.iter()
            .position(|a| a == name)
            .and_then(|i| args.get(i + 1).cloned())
    }
    let app = match flag(args, "--app") {
        Some(v) if !v.is_empty() => v,
        _ => {
            eprintln!("specialize cf_function_proxy : missing --app <app>");
            std::process::exit(2);
        }
    };
    let worker_url_env = match flag(args, "--worker-url-env") {
        Some(v) if !v.is_empty() => v,
        _ => {
            eprintln!("specialize cf_function_proxy : missing --worker-url-env <env-var name>");
            std::process::exit(2);
        }
    };
    let auth_secret_env = match flag(args, "--auth-secret-env") {
        Some(v) if !v.is_empty() => v,
        _ => {
            eprintln!("specialize cf_function_proxy : missing --auth-secret-env <env-var name>");
            std::process::exit(2);
        }
    };
    let allow_methods = flag(args, "--allow-methods")
        .unwrap_or_else(|| "[\"GET\",\"POST\"]".to_string());
    let output = flag(args, "--output")
        .unwrap_or_else(|| "./functions/api/[[route]].js".to_string());
    let auth_mode = flag(args, "--auth-mode").unwrap_or_else(|| "inject".to_string());
    if auth_mode != "inject" && auth_mode != "enforce" {
        eprintln!("specialize cf_function_proxy : --auth-mode must be inject|enforce (got {:?})", auth_mode);
        std::process::exit(2);
    }

    let js = storehouse::specializer::cf_function_proxy::emit_proxy(
        &app,
        &worker_url_env,
        &auth_secret_env,
        &allow_methods,
        &auth_mode,
    );

    let out_path = std::path::PathBuf::from(&output);
    if let Some(parent) = out_path.parent() {
        if let Err(e) = std::fs::create_dir_all(parent) {
            eprintln!("cannot create {}: {}", parent.display(), e);
            std::process::exit(1);
        }
    }
    if let Err(e) = std::fs::write(&out_path, &js) {
        eprintln!("cannot write {}: {}", out_path.display(), e);
        std::process::exit(1);
    }
    eprintln!("wrote {} bytes to {}", js.len(), out_path.display());
}

/// `storehouse specialize embedded_bluebooks --app <app>
///   --root <path> --primary <basename> [--extensions <csv>]
///   --output <path>`
///
/// Renders the WASM Worker's embedded.rs — the static
/// `&[(&str, &str)]` slice that compiles a project's bluebook tree
/// into the Worker binary so cold starts hit RAM, not R2. Required
/// flags : `--app`, `--root`, `--primary`, `--output`. Optional
/// `--extensions` is a comma-joined list of extensions (no dot ;
/// default `bluebook,hecksagon,world,fixtures`).
///
/// Re-runs are idempotent — same tree + flags → byte-identical
/// output. The bluebook_count is reported on stderr.
fn run_specialize_embedded_bluebooks(args: &[String]) {
    fn flag(args: &[String], name: &str) -> Option<String> {
        args.iter()
            .position(|a| a == name)
            .and_then(|i| args.get(i + 1).cloned())
    }
    let app = match flag(args, "--app") {
        Some(v) if !v.is_empty() => v,
        _ => {
            eprintln!("specialize embedded_bluebooks : missing --app <app>");
            std::process::exit(2);
        }
    };
    let root = match flag(args, "--root") {
        Some(v) if !v.is_empty() => v,
        _ => {
            eprintln!("specialize embedded_bluebooks : missing --root <path>");
            std::process::exit(2);
        }
    };
    let primary = match flag(args, "--primary") {
        Some(v) if !v.is_empty() => v,
        _ => {
            eprintln!("specialize embedded_bluebooks : missing --primary <basename>");
            std::process::exit(2);
        }
    };
    let extensions_csv = flag(args, "--extensions")
        .unwrap_or_else(|| "bluebook,hecksagon,world,fixtures".to_string());
    let output = match flag(args, "--output") {
        Some(v) if !v.is_empty() => v,
        _ => {
            eprintln!("specialize embedded_bluebooks : missing --output <path>");
            std::process::exit(2);
        }
    };

    let extensions: Vec<&str> = extensions_csv.split(',').filter(|s| !s.is_empty()).collect();
    let rs = storehouse::specializer::embedded_bluebooks::emit_embedded_rs(
        std::path::Path::new(&root),
        &app,
        &primary,
        &extensions,
    );

    let out_path = std::path::PathBuf::from(&output);
    if let Some(parent) = out_path.parent() {
        if let Err(e) = std::fs::create_dir_all(parent) {
            eprintln!("cannot create {}: {}", parent.display(), e);
            std::process::exit(1);
        }
    }
    if let Err(e) = std::fs::write(&out_path, &rs) {
        eprintln!("cannot write {}: {}", out_path.display(), e);
        std::process::exit(1);
    }
    let tuple_count = rs.matches("\n    (\"").count();
    eprintln!(
        "wrote {} bytes ({} embedded files) to {}",
        rs.len(),
        tuple_count,
        out_path.display()
    );
}

/// Locate the repository root for the `specialize` subcommand.
///
/// Prefers `heki::repo_root()` (executable-anchored, worktree-aware —
/// skips `.claude/worktrees/agent-XXX/` matches and finds the real
/// hecks checkout). Falls back to `env::current_dir()` when the
/// executable-walk returns None — invocation convention from a
/// non-test terminal is `storehouse specialize …` run from the repo
/// root (same as `bin/specialize` on the Ruby side).
///
/// The test harness in rust/tests/specializer_golden_test.rs sets
/// cwd to its CARGO_MANIFEST_DIR/.. which equals the worktree root
/// when tests run inside an agent worktree. The cwd-fallback would
/// pick the worktree's hecks_conception/ copy and downstream
/// specializers (e.g. system_prompt's shape at ../miette/...) would
/// fail because the worktree's parent is .claude/worktrees/, not
/// the projects root that holds sibling miette/. Going through
/// heki::repo_root() finds the canonical checkout regardless.
fn specialize_repo_root() -> Result<std::path::PathBuf, Box<dyn std::error::Error>> {
    if let Some(root) = storehouse::heki::repo_root() {
        return Ok(root);
    }
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
///   storehouse heki read   <file.heki>
///   storehouse heki append <file.heki> key=val key2=val2
///   storehouse heki upsert <file.heki> key=val key2=val2
///   storehouse heki delete <file.heki> <id>
///   storehouse heki latest <file.heki>
///
/// Query shapes (i37 Phase A — replace python3 -c invocations):
///   storehouse heki get           <file.heki> <id> [<field>]
///   storehouse heki list          <file.heki> [--where k=v]... [--order f[:asc|desc|enum=a,b,c]]
///                                             [--fields a,b,c] [--format json|tsv|kv]
///   storehouse heki count         <file.heki> [--where k=v]...
///   storehouse heki next-ref      <file.heki> [--prefix i] [--field ref]
///   storehouse heki latest-field  <file.heki> <field>
///   storehouse heki values        <file.heki> <field>
///   storehouse heki mark          <file.heki> --where k=v [--where k=v]... --set k=v [--set k=v]...
///   storehouse heki seconds-since <file.heki> <field>
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
        eprintln!("Usage: storehouse heki <cmd> <file.heki> [args...]");
        eprintln!("Commands: read latest append upsert delete snapshot");
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
        "retain"        => heki_cmd_retain(file, rest),
        "snapshot"      => heki_cmd_snapshot(file),
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
            eprintln!("Available: read latest append upsert delete snapshot get list count ids \
                       next-ref latest-field values mark seconds-since");
            std::process::exit(1);
        }
    }
}

/// Snapshot a heki file on demand. Useful before risky manual ops.
/// Prints the snapshot path on success ; prints a notice and exits 0
/// if the source file doesn't exist (idempotent).
fn heki_cmd_snapshot(file: &str) {
    match heki::snapshot(file) {
        Ok(Some(snap)) => println!("{}", snap),
        Ok(None) => println!("(no file at {} — nothing to snapshot)", file),
        Err(e) => { eprintln!("{}", e); std::process::exit(1); }
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

/// Extract `--reason "<text>"` from a CLI arg list. Returns the reason
/// and the remaining args. The reason is REQUIRED for write subcommands
/// (append / upsert / delete) — without it, the write is a discipline
/// gap. Use a domain command (`storehouse $AGG <Aggregate>.<Command>`)
/// instead, or pass --reason to acknowledge the out-of-band nature.
fn extract_reason<'a>(rest: &'a [String]) -> Option<(String, Vec<&'a String>)> {
    let mut iter = rest.iter().peekable();
    let mut reason: Option<String> = None;
    let mut remaining: Vec<&String> = Vec::new();
    while let Some(arg) = iter.next() {
        if arg == "--reason" {
            if let Some(next) = iter.next() {
                reason = Some(next.clone());
                continue;
            }
            eprintln!("--reason requires a value");
            std::process::exit(1);
        }
        if let Some(stripped) = arg.strip_prefix("--reason=") {
            reason = Some(stripped.to_string());
            continue;
        }
        remaining.push(arg);
    }
    reason.map(|r| (r, remaining))
}

fn require_reason(op: &str, rest: &[String]) -> (String, Vec<String>) {
    match extract_reason(rest) {
        Some((reason, rem)) => (reason, rem.into_iter().cloned().collect()),
        None => {
            eprintln!("storehouse heki {} requires --reason \"<why>\" — direct heki", op);
            eprintln!("writes bypass the dispatch path. Use a domain command instead, or");
            eprintln!("pass --reason to mark this as an out-of-band write (test setup,");
            eprintln!("migration, bootstrap seed). The reason is recorded in the audit log.");
            std::process::exit(1);
        }
    }
}

fn heki_cmd_append(file: &str, rest: &[String]) {
    let (reason, remaining) = require_reason("append", rest);
    let attrs = heki::parse_attrs(&remaining);
    match heki::append(file, &attrs, heki::WriteContext::OutOfBand { reason: &reason }) {
        Ok(rec) => println!("{}", serde_json::to_string_pretty(&rec).unwrap_or_default()),
        Err(e)  => { eprintln!("{}", e); std::process::exit(1); }
    }
}

fn heki_cmd_upsert(file: &str, rest: &[String]) {
    let (reason, remaining) = require_reason("upsert", rest);
    let attrs = heki::parse_attrs(&remaining);
    match heki::upsert(file, &attrs, heki::WriteContext::OutOfBand { reason: &reason }) {
        Ok(rec) => println!("{}", serde_json::to_string_pretty(&rec).unwrap_or_default()),
        Err(e)  => { eprintln!("{}", e); std::process::exit(1); }
    }
}

fn heki_cmd_delete(file: &str, rest: &[String]) {
    let (reason, remaining) = require_reason("delete", rest);
    let id = match remaining.first() {
        Some(s) => s.as_str(),
        None => {
            eprintln!("Usage: storehouse heki delete <file.heki> <id> --reason \"<why>\"");
            std::process::exit(1);
        }
    };
    // Snapshot before destructive op — out-of-band deletes are exactly
    // the case we want backup evidence for.
    match heki::snapshot(file) {
        Ok(Some(snap)) => eprintln!("[heki:snapshot] {} → {}", file, snap),
        Ok(None) => {}
        Err(e) => eprintln!("[heki:snapshot] warning: {}", e),
    }
    match heki::delete(file, id, heki::WriteContext::OutOfBand { reason: &reason }) {
        Ok(true)  => println!("deleted {}", id),
        Ok(false) => { eprintln!("not found: {}", id); std::process::exit(1); }
        Err(e)    => { eprintln!("{}", e); std::process::exit(1); }
    }
}

/// `heki retain <file> <id> --reason "<why>"` — filter-rewrite a store
/// to keep only the named record. Used to clean up i151 singleton-leak
/// orphans : aggregate stores accumulated thousands of records when
/// every cascade tick minted a new id ; the canonical natural-key
/// record is the only one with real state. Snapshots the source before
/// rewriting so the prior store can be recovered.
fn heki_cmd_retain(file: &str, rest: &[String]) {
    let (reason, remaining) = require_reason("retain", rest);
    let id = match remaining.first() {
        Some(s) => s.as_str(),
        None => {
            eprintln!("Usage: storehouse heki retain <file.heki> <id> --reason \"<why>\"");
            std::process::exit(1);
        }
    };
    let store = match heki::read(file) {
        Ok(s) => s,
        Err(e) => { eprintln!("{}", e); std::process::exit(1); }
    };
    let kept = match store.get(id) {
        Some(r) => r.clone(),
        None => {
            eprintln!("heki retain : no record with id={} in {}", id, file);
            std::process::exit(1);
        }
    };
    let dropped = store.len().saturating_sub(1);
    // Snapshot before destructive op — same pattern heki delete uses.
    match heki::snapshot(file) {
        Ok(Some(snap)) => eprintln!("[heki:snapshot] {} → {}", file, snap),
        Ok(None) => {}
        Err(e) => eprintln!("[heki:snapshot] warning: {}", e),
    }
    let mut new_store = heki::Store::new();
    new_store.insert(id.to_string(), kept);
    match heki::write(file, &new_store, heki::WriteContext::OutOfBand { reason: &reason }) {
        Ok(_) => println!("retained id={} ; {} record(s) dropped", id, dropped),
        Err(e) => { eprintln!("{}", e); std::process::exit(1); }
    }
}

// -------- New query commands ------------------------------------------------

fn heki_cmd_get(file: &str, rest: &[String]) {
    let id = match rest.first() {
        Some(s) => s.as_str(),
        None => {
            eprintln!("Usage: storehouse heki get <file.heki> <id> [<field>]");
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
            eprintln!("Usage: storehouse heki latest-field <file.heki> <field>");
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
            eprintln!("Usage: storehouse heki values <file.heki> <field>");
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
    let (reason, remaining) = require_reason("mark", rest);
    let rest = &remaining;
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
        // Snapshot before destructive overwrite — `mark` rewrites the
        // whole store in one go, which makes targeting mistakes hard
        // to recover from without a backup.
        match heki::snapshot(file) {
            Ok(Some(snap)) => eprintln!("[heki:snapshot] {} → {}", file, snap),
            Ok(None) => {}
            Err(e) => eprintln!("[heki:snapshot] warning: {}", e),
        }
        if let Err(e) = heki::write(file, &store, heki::WriteContext::OutOfBand { reason: &reason }) {
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
            eprintln!("Usage: storehouse heki seconds-since <file.heki> <field>");
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
fn dump_hecksagon_json(hex: &storehouse::hecksagon_ir::Hecksagon) -> serde_json::Value {
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
    let llm_adapters: Vec<serde_json::Value> = hex.llm_adapters.iter().map(|la| {
        serde_json::json!({
            "name":                 la.name,
            "prompt_template":      la.prompt_template,
            "model":                la.model,
            "max_tokens":           la.max_tokens,
            "trigger_on":           la.trigger_on,
            "response_into_target": la.response_into_target,
            "response_into_attr":   la.response_into_attr,
            "backend":              la.backend,
        })
    }).collect();
    // i220 sub-gap 5 (compute-adapter-primitive) — parity dump for
    // the new `:compute` family. Mirrors llm_adapters' shape minus
    // prompt_template / model / max_tokens / backend (compute has
    // no prompt + no provider) ; carries `function_name` instead
    // (the registry key the runtime resolves at dispatch time).
    let compute_adapters: Vec<serde_json::Value> = hex.compute_adapters.iter().map(|ca| {
        serde_json::json!({
            "name":                 ca.name,
            "function_name":        ca.function_name,
            "trigger_on":           ca.trigger_on,
            "response_into_target": ca.response_into_target,
            "response_into_attr":   ca.response_into_attr,
        })
    }).collect();
    serde_json::json!({
        "name":             hex.name,
        // Phase 1 of adapter-family activation : meta-layer files
        // (Hecks.adapter_family / Hecks.provider / Hecks.behavior_kind)
        // carry a kind discriminator. Plain Hecks.hecksagon files emit
        // null. Mirrors parity/canonical_ir.rb :: dump_hecksagon — both
        // halves emit the field unconditionally so the canonical JSON
        // shape is byte-equal regardless of whether framework_kind is
        // populated.
        "framework_kind":   hex.framework_kind,
        "persistence":      hex.persistence,
        "subscriptions":    hex.subscriptions,
        "io_adapters":      io_adapters,
        "shell_adapters":   shell_adapters,
        "llm_adapters":     llm_adapters,
        "compute_adapters": compute_adapters,
        "gates":            gates,
    })
}

/// Canonical JSON for a `.world` file — matches the shape the Ruby
/// parity harness emits for `Hecksagon::Structure::World#to_canonical_h`.
fn dump_world_json(world: &storehouse::world::ir::World) -> serde_json::Value {
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
    let servers = storehouse::world::attach::dump_servers_json(world);
    serde_json::json!({
        "name":     world.name,
        "purpose":  world.purpose,
        "vision":   world.vision,
        "audience": world.audience,
        "concerns": concerns,
        "configs":  configs,
        "servers":  servers,
    })
}

/// Derive the being name from argv[0].
/// "miette" or "/path/to/miette" -> "Miette"
/// "summer" or "/path/to/summer" -> "Summer"
/// Anything else (storehouse, etc) -> "Miette" (default)
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
    let world = storehouse::world::parser::parse(&content);
    let cfg = world.config_for("ollama")?;
    let model = cfg.get("model")?.to_string();
    let url   = cfg.get("url")?.to_string();
    Some((model, url))
}

/// Read the SQLite db path from the project's *.world `sqlite` block.
/// The db FILENAME is environment config, not adapter wiring, so it
/// lives in `.world` (sibling to heki's `dir`) — the hecksagon declares
/// only `adapter :sqlite`. Checks agg_dir itself then its parent (the
/// .world may sit next to the aggregates or one level up). Routes
/// through world_parser, the one canonical shape for .world consumers.
fn find_world_sqlite_path(agg_dir: &str) -> Option<String> {
    let p = std::path::Path::new(agg_dir);
    let world_path = find_world_file(p)
        .or_else(|| p.parent().and_then(find_world_file))?;
    let content = fs::read_to_string(&world_path).ok()?;
    let world = storehouse::world::parser::parse(&content);
    let cfg = world.config_for("sqlite")?;
    cfg.get("path").or_else(|| cfg.get("file")).or_else(|| cfg.get("db"))
        .map(|s| s.to_string())
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
        let hex = storehouse::hecksagon_parser::parse(&source);
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
    let combined = load_combined_domain(&agg_dir);
    let mut rt = Runtime::boot_with_data_dir(combined, Some(data_dir));
    storehouse::runtime::adapter_terminal::run(&mut rt, being);
}


/// Find the info dir for run_loop / run_clock / dispatch_hecksagon.
///
/// Resolution order, bluebook-first :
///   1. If a sibling `.world` file declares `heki { dir "..." }`,
///      use that — the world bluebook IS the source of truth.
///      Used by the differential fuzzer for per-seed isolation
///      (each `/tmp/fuzz-<seed>` tree carries its own `information/`
///      + `fuzz.world`) and by any caller that wires a sibling world.
///   2. Otherwise fall back to `heki::resolve_info_dir` (the i154
///      canonical helper — repo-root-anchored, HECKS_INFO-aware).
///
/// Earlier this function ignored `aggregates_path` entirely and
/// always returned the canonical info dir — that closed the i149/i153
/// class of bugs where boot wrote one place while daemons read
/// another, but it also broke the fuzzer's per-seed isolation
/// (every seed wrote to one shared dir, contaminating across seeds).
/// Reading the .world file restores per-seed isolation without
/// reopening the boot/daemon split, because the canonical fallback
/// is unchanged for callers without a sibling .world.
fn find_world_heki_dir(aggregates_path: &str) -> Option<String> {
    if let Some(world_dir) = read_world_heki_dir(aggregates_path) {
        return Some(world_dir);
    }
    Some(storehouse::heki::resolve_info_dir().to_string_lossy().into_owned())
}

/// Helper for `find_world_heki_dir` : look for a `.world` file
/// alongside `aggregates_path`, parse it, and read `heki.dir`.
/// Returns `None` on any missing piece — safe to fall through.
fn read_world_heki_dir(aggregates_path: &str) -> Option<String> {
    use std::path::Path;
    let agg = Path::new(aggregates_path);
    // The .world file sits next to the aggregates/ directory :
    //   - aggregates_path is a dir → world is in its parent.
    //   - aggregates_path is a file (one bluebook) → world is two
    //     levels up (e.g. aggregates/foo.bluebook → ../).
    let world_dir = if agg.is_dir() {
        agg.parent()?
    } else {
        agg.parent()?.parent()?
    };
    let world_file = std::fs::read_dir(world_dir).ok()?
        .filter_map(|e| e.ok())
        .find(|e| e.path().extension().map_or(false, |ext| ext == "world"))?
        .path();
    let source = std::fs::read_to_string(&world_file).ok()?;
    let world = storehouse::world::parser::parse(&source);
    let dir_value = world.config_for("heki").and_then(|c| c.get("dir"))?;
    let resolved = world_dir.join(dir_value);
    if resolved.exists() {
        Some(resolved.to_string_lossy().into_owned())
    } else {
        None
    }
}

/// i221 — load every `*.hecksagon` reachable from agg_dir (the agg_dir
/// itself + sibling hecksagon roots discovered the same way bluebooks
/// are). Used by `Runtime::boot_with_hecksagons` so the LLM dispatcher
/// hook can resolve named `:llm` adapters at runtime.
fn load_all_hecksagons(agg_dir: &str) -> Vec<storehouse::hecksagon_ir::Hecksagon> {
    let mut out = Vec::new();
    // Dedup by canonical path : the primary agg_dir walk and the
    // sibling-repo walk below can otherwise both pick up the same
    // file (e.g. `miette/body/voice/voice.hecksagon` is visited both
    // by an agg_dir at `miette/body/` and by the sibling fan-out into
    // `miette/`), which silently doubled :tts dispatches and re-played
    // every audio render twice.
    let mut seen: std::collections::HashSet<std::path::PathBuf> = std::collections::HashSet::new();
    fn walk(
        dir: &std::path::Path,
        out: &mut Vec<storehouse::hecksagon_ir::Hecksagon>,
        seen: &mut std::collections::HashSet<std::path::PathBuf>,
    ) {
        let Ok(entries) = fs::read_dir(dir) else { return };
        for entry in entries.flatten() {
            let p = entry.path();
            let name = p.file_name().and_then(|n| n.to_str()).unwrap_or("");
            if matches!(name, ".git" | "target" | "information" | ".claude"
                | "node_modules" | "generated" | "fixtures" | "snippets") {
                continue;
            }
            if p.is_dir() {
                walk(&p, out, seen);
            } else if p.extension().map(|e| e == "hecksagon").unwrap_or(false) {
                let key = std::fs::canonicalize(&p).unwrap_or_else(|_| p.clone());
                if !seen.insert(key) { continue; }
                if let Ok(source) = fs::read_to_string(&p) {
                    out.push(storehouse::hecksagon_parser::parse(&source));
                }
            }
        }
    }
    walk(std::path::Path::new(agg_dir), &mut out, &mut seen);
    // i221 follow-up — mirror load_combined_domain's parent walk so
    // hecksagons in sibling roots participate in :llm adapter
    // resolution. Without this the named-adapter chain
    // (Dream.RecordImage → :dream_image) silently skipped because
    // body/dream/dream.hecksagon lives in ../miette, not under agg_dir.
    // Same skip-when-missing semantics as the bluebook walk : sibling
    // repos that aren't checked out (CI on hecks alone) are silently
    // absent.
    if let Some(repo_root) = storehouse::heki::repo_root() {
        // Sibling repos via canonical repo_root — mirrors
        // load_combined_domain's miette/miette_family walk (line ~2006).
        // Use heki::repo_root() because agg_dir can be relative ; from
        // a worktree under .claude/worktrees/agent-XXX/, parent.parent()
        // dead-ends at .claude/, but heki::repo_root() walks up from
        // current_exe to find the canonical hecks/ checkout regardless.
        for sibling in &["miette", "miette_family"] {
            if let Ok(canonical) = std::fs::canonicalize(repo_root.join("..").join(sibling)) {
                if canonical.is_dir() && canonical != std::path::Path::new(agg_dir) {
                    walk(&canonical, &mut out, &mut seen);
                }
            }
        }
        // Top-level buckets at hecks repo root (mirrors the
        // post-i118-R3 bluebook walk : runtime/, discipline/, codegen/,
        // cli/, integrations/, tools/).
        for bucket in &["runtime", "discipline", "codegen", "cli",
                        "integrations", "tools", "capabilities"] {
            let bucket_dir = repo_root.join(bucket);
            if bucket_dir.is_dir() && bucket_dir != std::path::Path::new(agg_dir) {
                walk(&bucket_dir, &mut out, &mut seen);
            }
        }
    }
    // World-config sqlite path (2026-05-23) — the db FILENAME is
    // environment config, not adapter wiring, so it lives in the
    // `.world` `sqlite` block (next to heki's `dir`), not hardcoded in
    // the hecksagon. The hecksagon declares only `adapter :sqlite` ;
    // here we fill its `db` option from `.world` so sqlite_db_path()
    // resolves it downstream. Only fills when the hecksagon hasn't
    // already set one (explicit hecksagon db: still wins, for tests).
    if let Some(db) = find_world_sqlite_path(agg_dir) {
        for hex in out.iter_mut() {
            if hex.persistence.as_deref() == Some("sqlite")
                && hex.persistence_option("db").is_none()
            {
                hex.persistence_options.push(("db".to_string(), db.clone()));
            }
        }
    }
    out
}

/// i221 — register the runtime's `:llm` providers from the env. The
/// `:test` provider is always present (in-memory ; no network) ; the
/// `:claude` and `:ollama` providers are added when their backends
/// are referenced by any loaded hecksagon's `:llm` adapter.
///
/// TestProvider fixture sources, in priority order :
///   1. `HECKS_LLM_FIXTURES` env var — explicit path to a single
///      fixtures file (TSV or Ruby DSL). Wins outright when set.
///   2. Sibling `<stem>.fixtures` files next to each loaded
///      `*.hecksagon` (gap3 / i220-3). The DrearmContent smoke and
///      any other PM-cascade test ships its canned French responses
///      next to the hecksagon they belong to ; the runtime auto-merges
///      them into one prompt-keyed map. Cleaner than forcing every
///      smoke to set HECKS_LLM_FIXTURES manually.
///   3. Lenient default (no fixtures) — TestProvider returns a
///      synthetic `[test-provider:unknown-prompt sha256=…]` placeholder
///      so the chain still flows ; useful while fixtures are still
///      being captured.
///
/// gap3 (i220-3) note : when `HECKS_LLM_PROVIDER=test` is also set,
/// `llm_dispatcher::call` overrides every adapter's backend to `:test`
/// regardless of what the hecksagon declared (`backend :claude`),
/// which is what makes the smoke deterministic without editing the
/// production hecksagon.
fn register_llm_providers(rt: &mut Runtime, agg_dir: &str) {
    use storehouse::runtime::llm_providers::{TestProvider, ClaudeProvider, OllamaProvider};
    // Test provider — always present. Loading order : explicit env
    // path > auto-discovered sibling files > lenient empty.
    let test_provider: Box<dyn storehouse::runtime::llm_providers::LlmProvider> =
        if let Ok(path) = std::env::var("HECKS_LLM_FIXTURES") {
            Box::new(TestProvider::from_fixtures_file(path))
        } else {
            let merged = collect_sibling_fixtures(agg_dir);
            if merged.is_empty() {
                Box::new(TestProvider::new(std::collections::HashMap::new()))
            } else {
                Box::new(TestProvider::new(merged))
            }
        };
    rt.register_llm_provider("test", test_provider);
    // Discover backends declared in hecksagons.
    let mut backends: std::collections::HashSet<String> = std::collections::HashSet::new();
    for h in &rt.hecksagons {
        for la in &h.llm_adapters {
            if let Some(b) = la.backend.as_deref() {
                backends.insert(b.to_string());
            }
        }
    }
    if backends.contains("claude") {
        rt.register_llm_provider("claude", Box::new(ClaudeProvider::new()));
    }
    if backends.contains("ollama") {
        let url = std::env::var("OLLAMA_URL")
            .unwrap_or_else(|_| "http://localhost:11434".to_string());
        rt.register_llm_provider("ollama", Box::new(OllamaProvider::new(url)));
    }
}

/// Auto-discover `*.fixtures` siblings of every loaded hecksagon and
/// fold their `input` → `response` pairs into one SHA-keyed map.
///
/// Walks the same roots `load_all_hecksagons` walks (agg_dir + sibling
/// repos like miette + top-level buckets) and pairs every `*.hecksagon`
/// with its `<stem>.fixtures` sibling when one exists. Missing siblings
/// are silently skipped — the lenient default still kicks in for any
/// adapter whose hecksagon ships without a companion fixtures file.
///
/// gap3 / i220-3 wiring : this is the function that makes
/// `body/dream/dream.fixtures` the canonical source of canned dream
/// responses for the dream_content smoke without forcing the smoke
/// to know that path explicitly. The same scan-roots that brought the
/// hecksagons in bring their fixtures siblings in.
fn collect_sibling_fixtures(
    agg_dir: &str,
) -> std::collections::HashMap<String, String> {
    use storehouse::runtime::llm_providers::TestProvider;
    let mut merged: std::collections::HashMap<String, String> = std::collections::HashMap::new();

    fn walk_for_fixtures(dir: &std::path::Path, out: &mut std::collections::HashMap<String, String>) {
        let Ok(entries) = fs::read_dir(dir) else { return };
        for entry in entries.flatten() {
            let p = entry.path();
            let name = p.file_name().and_then(|n| n.to_str()).unwrap_or("");
            // Mirror load_all_hecksagons's skip set so we don't
            // accidentally pick up codegen shape fixtures or test-
            // capture bins. The :test provider should ONLY see
            // adapter-aligned response fixtures.
            if matches!(name, ".git" | "target" | "information" | ".claude"
                | "node_modules" | "generated" | "fixtures" | "snippets") {
                continue;
            }
            if p.is_dir() {
                walk_for_fixtures(&p, out);
                continue;
            }
            // We're looking for `<stem>.fixtures` siblings of `<stem>.hecksagon`.
            // Keying off the .hecksagon presence keeps shape/spec/etc. fixtures
            // (which carry Section / Aggregate rows, not input/response) out.
            if p.extension().map(|e| e == "hecksagon").unwrap_or(false) {
                let Some(stem) = p.file_stem().and_then(|s| s.to_str()) else { continue };
                let Some(parent) = p.parent() else { continue };
                let sibling = parent.join(format!("{}.fixtures", stem));
                if !sibling.exists() { continue; }
                let Ok(contents) = std::fs::read_to_string(&sibling) else { continue };
                merge_fixtures_contents(&contents, out);
            }
        }
    }

    fn merge_fixtures_contents(contents: &str, out: &mut std::collections::HashMap<String, String>) {
        let trimmed = contents.lines()
            .find(|l| !l.trim().is_empty() && !l.trim().starts_with('#'))
            .unwrap_or("").trim();
        if trimmed.starts_with("Hecks.fixtures") {
            let parsed = storehouse::fixtures_parser::parse(contents);
            for fx in &parsed.fixtures {
                let mut input: Option<&str> = None;
                let mut response: Option<&str> = None;
                for (k, v) in &fx.attributes {
                    match k.as_str() {
                        "input"    => input = Some(v.as_str()),
                        "response" => response = Some(v.as_str()),
                        _ => {}
                    }
                }
                if let (Some(p), Some(r)) = (input, response) {
                    out.insert(TestProvider::hash_for(p), r.to_string());
                }
            }
        } else {
            for line in contents.lines() {
                let l = line.trim_end_matches('\r');
                if l.is_empty() || l.starts_with('#') { continue; }
                if let Some((digest, body)) = l.split_once('\t') {
                    let d = digest.trim().to_string();
                    if d.len() == 64 && d.chars().all(|c| c.is_ascii_hexdigit()) {
                        out.insert(d, body.to_string());
                    }
                }
            }
        }
    }

    walk_for_fixtures(std::path::Path::new(agg_dir), &mut merged);
    if let Some(repo_root) = storehouse::heki::repo_root() {
        for sibling in &["miette", "miette_family"] {
            if let Ok(canonical) = std::fs::canonicalize(repo_root.join("..").join(sibling)) {
                if canonical.is_dir() && canonical != std::path::Path::new(agg_dir) {
                    walk_for_fixtures(&canonical, &mut merged);
                }
            }
        }
        for bucket in &["runtime", "discipline", "codegen", "cli",
                        "integrations", "tools", "capabilities"] {
            let bucket_dir = repo_root.join(bucket);
            if bucket_dir.is_dir() && bucket_dir != std::path::Path::new(agg_dir) {
                walk_for_fixtures(&bucket_dir, &mut merged);
            }
        }
    }
    merged
}

/// `storehouse serve-stdio <agg-dir>` — boot the resident runtime ONCE
/// then hand off to the warm serve loop.
///
/// The boot is byte-for-byte the dispatch_hecksagon boot
/// (find_world_heki_dir + load_combined_domain + load_all_hecksagons +
/// Runtime::boot_with_hecksagons + register_llm_providers) so a warm
/// dispatch is indistinguishable from a cold one except for latency —
/// every adapter family (:llm / :claude_tool / :mcp / :exec / :tts) and
/// the LLM provider registry hang off rt.hecksagons exactly as in the
/// one-shot path.
///
/// Protocol correctness comes from the sentinel-line prefix
/// (run_serve::RESULT_SENTINEL), NOT from the log level : the serve
/// child routes every non-sentinel stdout line to its own stderr, so
/// the result line is always findable amid any incidental log/adapter
/// output. STOREHOUSE_LOG defaults to quiet here only for log-volume
/// hygiene (it silences event/cascade chatter ; the terse `dispatch`
/// line still prints at quiet — the sentinel handles it regardless).
///
/// [antibody-exempt: rust/src/main.rs run_serve_stdio — kernel-surface
///  CLI primitive. Boots the resident runtime once and hands off to the
///  warm serve loop (storehouse::run_serve). Same i80-family contract as
///  the sibling run_loop / run_daemon / run_clock / run_follow arms : a
///  thin file-I/O + boot boundary around a bluebook-described dispatch
///  body. The serve loop's dispatch is byte-identical to the one-shot
///  dispatch_hecksagon path ; this just pays the boot once. Retires
///  alongside the rest of the run_* family once cli.bluebook (i80) lands
///  and CLI routing becomes declarative.]
fn run_serve_stdio(agg_dir: &str) {
    if agg_dir.is_empty() || !std::path::Path::new(agg_dir).is_dir() {
        eprintln!("usage: storehouse serve-stdio <aggregates-dir>");
        std::process::exit(2);
    }
    let (mut rt, hecksagon_llm, ollama_config) = boot_serve_runtime(agg_dir);
    let legacy_hook = make_serve_legacy_hook(hecksagon_llm, ollama_config);
    let code = storehouse::run_serve::run(&mut rt, Some(&legacy_hook));
    std::process::exit(code);
}

/// `storehouse serve-socket <agg-dir> [socket-path]` — boot the resident
/// runtime ONCE then hand off to the unix-socket serve loop. The warm
/// runtime lives as an overmind daemon (body), so it survives a Claude
/// restart : the MCP becomes a thin socket client that reconnects
/// without re-paying the ~660ms boot. Boot + dispatch body are
/// byte-identical to serve-stdio (shared `boot_serve_runtime` +
/// `run_serve::handle_request`) ; only the transport differs.
///
/// If `socket_path` is `None`, binds the deterministic per-root path the
/// MCP client also derives (`run_serve::sock_path_for_root(agg_dir)`),
/// so the daemon and client agree on the address with no coordination.
///
/// [antibody-exempt: rust/src/main.rs run_serve_socket — kernel-surface
///  CLI primitive, sibling of run_serve_stdio. Boots the resident
///  runtime once and hands off to the warm unix-socket serve loop
///  (storehouse::run_serve::socket). The serve loop's dispatch is
///  byte-identical to the one-shot dispatch_hecksagon path. Retires
///  alongside the rest of the run_* family once cli.bluebook (i80)
///  lands and CLI routing becomes declarative.]
fn run_serve_socket(agg_dir: &str, socket_path: Option<&str>) {
    if agg_dir.is_empty() || !std::path::Path::new(agg_dir).is_dir() {
        eprintln!("usage: storehouse serve-socket <aggregates-dir> [socket-path]");
        std::process::exit(2);
    }
    let sock_path = match socket_path {
        Some(p) => std::path::PathBuf::from(p),
        None => storehouse::run_serve::sock_path_for_root(agg_dir),
    };
    let (mut rt, hecksagon_llm, ollama_config) = boot_serve_runtime(agg_dir);
    let legacy_hook = make_serve_legacy_hook(hecksagon_llm, ollama_config);
    let code = storehouse::run_serve::socket::run(&mut rt, &sock_path, Some(&legacy_hook));
    std::process::exit(code);
}

/// Boot the resident runtime EXACTLY like dispatch_hecksagon
/// (find_world_heki_dir + load_combined_domain + load_all_hecksagons +
/// Runtime::boot_with_hecksagons + register_llm_providers) so warm
/// dispatches produce byte-identical .heki to the cold one-shot path.
/// Returns the booted runtime plus the resolved legacy conversational-
/// LLM config (hecksagon :llm triple, else .world ollama pair) so the
/// caller can build the post-dispatch adapter_llm hook. Shared by both
/// serve transports.
fn boot_serve_runtime(
    agg_dir: &str,
) -> (Runtime, Option<(String, String, String)>, Option<(String, String)>) {
    // Default the bus log to quiet for the resident process — explicit
    // STOREHOUSE_LOG still wins for debugging.
    if std::env::var("STOREHOUSE_LOG").is_err() {
        std::env::set_var("STOREHOUSE_LOG", "quiet");
    }
    let data_dir = find_world_heki_dir(agg_dir)
        .unwrap_or_else(|| format!("{}/data", agg_dir.trim_end_matches('/')));
    // Accept a single bluebook file as well as a directory root, so
    // `storehouse query <file.bluebook> <verb>` works (MCP doc says
    // "root-or-bluebook"). A file parses to its own domain ; a directory
    // loads the combined domain.
    let combined = if std::path::Path::new(agg_dir).is_file() {
        parser::parse(&fs::read_to_string(agg_dir).unwrap_or_default())
    } else {
        load_combined_domain(agg_dir)
    };
    let hecksagons = load_all_hecksagons(agg_dir);
    let mut rt = Runtime::boot_with_hecksagons(combined, Some(data_dir), hecksagons);
    storehouse::world::attach::apply_per_domain_world_dirs(&mut rt, agg_dir);
    register_llm_providers(&mut rt, agg_dir);
    storehouse::world::attach::attach_world_servers(&mut rt, agg_dir);
    let hecksagon_llm = find_hecksagon_llm_config(agg_dir);
    let ollama_config = find_world_ollama_config(agg_dir);
    (rt, hecksagon_llm, ollama_config)
}

/// Build the post-dispatch legacy-LLM hook closure both serve
/// transports pass to the loop. Mirrors dispatch_hecksagon's
/// adapter_llm pass (hecksagon :llm backend wins, else .world ollama)
/// so warm .heki stays byte-identical to the cold path.
fn make_serve_legacy_hook(
    hecksagon_llm: Option<(String, String, String)>,
    ollama_config: Option<(String, String)>,
) -> impl Fn(&mut Runtime, &str, &str, &str) {
    move |rt: &mut Runtime, agg_type: &str, agg_id: &str, command: &str| {
        if let Some(state) = rt.find(agg_type, agg_id).cloned() {
            let repo_key = storehouse::runtime::repo_lookup_key(&rt.repositories, agg_type);
            if let Some(repo) = repo_key.as_ref().and_then(|k| rt.repositories.get_mut(k)) {
                if let Some((backend, model, url)) = hecksagon_llm.as_ref() {
                    let triple = (backend.as_str(), model.as_str(), url.as_str());
                    storehouse::runtime::adapter_llm::resolve(
                        repo, &state, Some(triple), agg_type, command);
                } else {
                    let config = ollama_config.as_ref().map(|(m, u)| (m.as_str(), u.as_str()));
                    storehouse::runtime::adapter_llm::resolve_ollama(
                        repo, &state, config, agg_type, command);
                }
            }
        }
    }
}

/// Dispatch a command through the hecksagon — merge all bluebooks, find the command, run it.
fn dispatch_hecksagon(agg_dir: &str, command: &str, attrs: std::collections::HashMap<String, serde_json::Value>) {
    let data_dir = find_world_heki_dir(agg_dir)
        .unwrap_or_else(|| format!("{}/data", agg_dir.trim_end_matches('/')));
    // Accept a single bluebook file as well as a directory root, so
    // `storehouse query <file.bluebook> <verb>` works (MCP doc says
    // "root-or-bluebook"). A file parses to its own domain ; a directory
    // loads the combined domain.
    let combined = if std::path::Path::new(agg_dir).is_file() {
        parser::parse(&fs::read_to_string(agg_dir).unwrap_or_default())
    } else {
        load_combined_domain(agg_dir)
    };
    let hecksagons = load_all_hecksagons(agg_dir);
    let mut rt = Runtime::boot_with_hecksagons(combined, Some(data_dir), hecksagons);
    storehouse::world::attach::apply_per_domain_world_dirs(&mut rt, agg_dir);
    register_llm_providers(&mut rt, agg_dir);
    storehouse::world::attach::attach_world_servers(&mut rt, agg_dir);

    // FQN-aware query resolution. Commands resolve their
    // Domain::Aggregate.Command form inside command_dispatch::resolve ;
    // queries need the same parsing here, else a
    // `Domain::Aggregate.snake_query` verb falls through to command
    // resolution and fails with UnknownCommand. Parse the FQN, match the
    // dot-tail against each aggregate's query names by snake_case, and
    // resolve through resolve_query_qualified (which targets the right
    // repo by context+aggregate).
    if let Some((head, tail)) = command.rsplit_once('.') {
        let segments: Vec<&str> = head.split("::").collect();
        if segments.len() == 2 {
            let agg = segments[1];
            let q_match = rt.domain.aggregates.iter()
                .filter(|a| a.name == agg)
                .find_map(|a| a.queries.iter()
                    .find(|q| storehouse::heki::snake_case(&q.name) == tail || q.name == tail)
                    .map(|q| (a.context.clone(), a.name.clone(), q.name.clone())));
            if let Some((ctx, agg_name, q_name)) = q_match {
                let str_attrs: std::collections::HashMap<String, String> = attrs.iter()
                    .map(|(k, v)| (k.clone(), v.as_str().unwrap_or("").to_string()))
                    .collect();
                println!("{}", rt.resolve_query_qualified(ctx.as_deref(), &agg_name, &q_name, &str_attrs));
                return;
            }
        }
    }

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
        let rt_attrs: std::collections::HashMap<String, storehouse::runtime::Value> = attrs.iter()
            .map(|(k, v)| (k.clone(), match v {
                serde_json::Value::String(s) => storehouse::runtime::Value::Str(s.clone()),
                _ => storehouse::runtime::Value::Str(v.to_string()),
            }))
            .collect();
        match rt.dispatch(command, rt_attrs) {
            Ok(result) => {
                // Runtime projection of StoryExecuted — dispatching
                // Plan::Story.Execute through the door triggers the
                // use-case runner as the projection of the emitted event.
                // Mirrors the same hook in run.rs (run_script path) so
                // both main.rs direct dispatch and the storehouse_route
                // path both fire the projection.
                if let Some(ref ev) = result.event {
                    if ev.name == "StoryExecuted" || ev.name == "SprintExecuted" {
                        let agg_id = ev.aggregate_id.clone();
                        // Use the plan domain's world-declared heki dir so the
                        // projection's reads find records in plan/.heki, not
                        // miette-state/information. collect_world_heki_dirs
                        // walks *.world files adjacent to agg_dir and maps
                        // category → resolved heki path.
                        let world_dirs = storehouse::world::attach::collect_world_heki_dirs(agg_dir);
                        let heki_dir = world_dirs.get("plan").cloned()
                            .or_else(|| storehouse::storehouse_router::info_dir());
                        if let Some(info_dir) = heki_dir {
                            // SprintExecuted fans out over the sprint's stories
                            // and runs each story's use cases DIRECTLY (not by
                            // re-dispatching Story.Execute, which would double-
                            // run). StoryExecuted runs one story's use cases.
                            let exit = if ev.name == "SprintExecuted" {
                                storehouse::story_runtime::sprint_execute(
                                    &agg_id, &info_dir, storehouse_route)
                            } else {
                                storehouse::story_runtime::storehouse_execute(
                                    &agg_id, &info_dir, storehouse_route)
                            };
                            if exit != 0 { std::process::exit(exit); }
                        } else {
                            eprintln!("[{}] cannot resolve heki dir — projection skipped", ev.name);
                        }
                    }
                }
                // Run LLM adapter if configured
                if let Some(state) = rt.find(&result.aggregate_type, &result.aggregate_id).cloned() {
                    let repo_key = storehouse::runtime::repo_lookup_key(&rt.repositories, &result.aggregate_type);
                    if let Some(repo) = repo_key.as_ref().and_then(|k| rt.repositories.get_mut(k)) {
                        if let Some((backend, model, url)) = hecksagon_llm.as_ref() {
                            let triple = (backend.as_str(), model.as_str(), url.as_str());
                            storehouse::runtime::adapter_llm::resolve(
                                repo, &state, Some(triple),
                                &result.aggregate_type, command);
                        } else {
                            let config = ollama_config.as_ref().map(|(m, u)| (m.as_str(), u.as_str()));
                            storehouse::runtime::adapter_llm::resolve_ollama(
                                repo, &state, config,
                                &result.aggregate_type, command);
                        }
                    }
                }
                let state = rt.find(&result.aggregate_type, &result.aggregate_id);
                let fields = state.map(|s| {
                    let mut map = serde_json::Map::new();
                    for (k, v) in &s.fields {
                        map.insert(k.clone(), match v {
                            storehouse::runtime::Value::Str(s) => serde_json::json!(s),
                            storehouse::runtime::Value::Int(n) => serde_json::json!(n),
                            storehouse::runtime::Value::Bool(b) => serde_json::json!(b),
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

/// i560 v2 FQN gate, extended to the cadence-family entry points
/// (`storehouse loop`, `storehouse run-loop --dispatch`, `storehouse
/// clock --segment`). Same contract as the main-dispatch gate :
/// every dispatch address typed at the CLI must carry `::`, naming
/// `Domain::Aggregate.Command` (commands, PascalCase) or
/// `Domain::Aggregate.query_name` (queries, snake_case). Short
/// forms (`Aggregate.Command`, bare `Command`) are rejected here so
/// the cadence CLIs stay aligned with the main dispatch entry
/// point. Internal cascade dispatch (drain_policies, trigger_command)
/// is unaffected — this validates user-typed addresses only.
///
/// `subcommand` names which CLI surface invoked the gate (used in
/// the error message). Exits 1 on rejection ; returns silently on
/// pass so callers can keep the existing `.split('.').last()` bare-
/// command extraction unchanged.
fn require_fqn_dispatch_address(subcommand: &str, address: &str) {
    if !address.contains("::") {
        eprintln!(
            "{} : dispatch address '{}' is a short-form address. The CLI requires the fully-qualified form Domain::Aggregate.Command (commands, PascalCase) or Domain::Aggregate.query_name (queries, snake_case). Example: 'Tools::Tools.Bash', 'Discipline::Macrophage.Run'.",
            subcommand, address
        );
        std::process::exit(1);
    }
}

/// Run the loop subcommand. Boots the runtime once, dispatches the named
/// command at the given cadence, exits cleanly on SIGINT / SIGTERM.
///
/// Args layout : storehouse loop <target> <Aggregate.Command> --every <dur> [k=v ...]
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
//     own session/process-group and the parent (this storehouse process)
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
// MACROPHAGE SUBCOMMAND — PostToolUse listener primitive
// (canonical name as of i553 ; old `enforce-edit` is a
//  deprecated alias still wired in main())
// ============================================================
//
// Reads JSON from stdin (Claude Code's PostToolUse contract),
// extracts tool_name and tool_input.file_path, classifies the
// extension, dispatches into the Macrophage aggregate, and routes
// imperative-edit complaints back to the agent via stderr + exit 2.
//
// Replaces ~/.claude/hooks/enforce_bluebook.sh (i104). Same family
// as run_loop / run_daemon : kernel-surface CLI primitive that a
// bluebook capability dispatches into. Bluebook brain
// (aggregates/discipline/macrophage/macrophage.bluebook) stays
// unchanged ; the shell glue retires.

fn run_macrophage(_args: &[String]) {
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
    let mut file_path = json.pointer("/tool_input/file_path")
        .and_then(|v| v.as_str()).unwrap_or("").to_string();

    // Bash-write detection (2026-05-02) : the cadence-primitive Phase 1b
    // agent flagged that kernel-surface .rs edits via Edit/Write got
    // enforced, but the same edits routed through `bash -c "python3
    // <<EOF\nopen('foo.rs','w').write(...)\nEOF"` slipped through —
    // the hook matcher was Edit|Write|MultiEdit only, so Bash bypassed
    // the discipline entirely. Tighten : when tool_name is Bash, parse
    // the command string for kernel-surface write patterns and treat
    // them as if an Edit had hit that path.
    //
    // Fast-path : if the command doesn't even mention a kernel-surface
    // extension, exit 0 immediately. Most bash invocations are reads
    // (git, grep, ls) ; we don't want macrophage overhead on every shell.
    if file_path.is_empty() && tool_name == "Bash" {
        let bash_cmd = json.pointer("/tool_input/command")
            .and_then(|v| v.as_str()).unwrap_or("").to_string();
        if let Some(target) = detect_bash_write_target(&bash_cmd) {
            file_path = target;
        }
    }

    if file_path.is_empty() {
        std::process::exit(0);
    }

    let kind = classify_file(&file_path);

    // For imperative files, ask the IR-query substrate first
    // (i122) ; if the corpus declares this file as dispatched (a
    // hecksagon ShellAdapter referencing it, a specializer target,
    // a capability runner row), exemption is structural — no
    // marker needed. Falls back to the central exempt_registry.heki
    // for cases the IR doesn't yet cover (the residual entries each
    // carry a named retirement arc in the inbox). When dispatched-
    // by-corpus fires, the kind decoration in the audit event names
    // who claimed the file, so the audit log shows WHY the edit was
    // exempt rather than just "exempt".
    let dispatch_info = if matches!(kind, FileKind::Imperative) {
        dispatch_lookup(&file_path)
    } else {
        None
    };
    let corpus_root_buf = resolve_aggregates_dir()
        .and_then(|d| std::path::Path::new(&d).parent().map(|p| p.to_path_buf()));
    let exempted = dispatch_info.is_some()
        || (matches!(kind, FileKind::Imperative)
            && corpus_root_buf.as_deref()
                .map(|root| storehouse::dispatch_query::is_imperative_exempt(&file_path, root))
                .unwrap_or(false));

    let cmd_name = match kind {
        FileKind::Bluebook   => "RecordBluebookEdit",
        FileKind::Imperative => if exempted { "RecordExemptedEdit" } else { "RecordImperativeEdit" },
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
    if let Some(ref info) = dispatch_info {
        // Record the IR-query verdict on the audit event so the
        // exempted edit carries a structured "why" instead of just
        // a flag. Source = where the dispatch declaration lives ;
        // kind = which kind of dispatch (specializer target, shell
        // adapter, runner row) ; identifier = the specific row in
        // that source.
        attrs.insert("dispatch_source".into(),
                     serde_json::Value::String(info.source.clone()));
        attrs.insert("dispatch_kind".into(),
                     serde_json::Value::String(info.kind.clone()));
        attrs.insert("dispatch_identifier".into(),
                     serde_json::Value::String(info.identifier.clone()));
        // Structured stderr line so the substrate is observable as
        // it works. Once the registry trim lands and the markers
        // retire, this is the only signal that an edit was exempt
        // and why.
        eprintln!(
            "[macrophage] exempt by corpus : {} ({} in {})",
            file_path, info.kind, info.source
        );
    }
    let _ = std::panic::catch_unwind(|| {
        // dispatch_hecksagon expects the bare command name (no
        // "Aggregate." prefix) ; the runtime resolves by command-
        // name within the loaded domain. Same shape run_loop uses.
        dispatch_hecksagon(&agg_dir, cmd_name, attrs.clone());
    });

    // --reason lint — fires on any .sh file (exempt or not) that has
    // a `heki append/upsert/delete/mark` invocation without --reason.
    // The discipline is structural : direct heki writes bypass the
    // dispatch path's audit log, so each must name why. Without this
    // gate, scripts silently exit non-zero on every write, fixtures
    // never seed, and tests pass-through with empty data. Pre-i112
    // we shipped that bug across many shells (pulse_organs, daydream,
    // consolidate, mint_musing, surface_musing, the test seeds
    // themselves) ; this hook makes the silent failure structurally
    // impossible going forward.
    if file_path.ends_with(".sh") {
        if let Some(violations) = unreasoned_heki_writes(&file_path) {
            let complaint = format!(
                "--reason missing on direct heki write in {} :\n  {}\n\n\
                 Direct heki writes (heki append / upsert / delete / mark) \
                 bypass the dispatch path's audit log. Each must pass \
                 --reason \"<why>\" so the audit trail names the gap that \
                 forced the bypass. Without it the runtime exits non-zero \
                 silently — discipline drift hides as a passing build.",
                file_path, violations.join("\n  "),
            );
            eprintln!("[macrophage] {}", complaint);
            std::process::exit(2);
        }
    }

    if matches!(kind, FileKind::Imperative) && !exempted {
        // Scope check (2026-05-13) : the bluebook-first rule applies only to
        // writes inside hecks-managed paths. Client repos (opt-website, emaho,
        // embryonaut-site) aren't bluebook-backed yet ; firing the complaint
        // on their edits is noise that paused the Lou Ann volunteer-page
        // sidequest tonight. corpus_root_buf was already resolved above for
        // the is_imperative_exempt lookup ; reuse it as the scope root. If
        // the touched file_path is outside the corpus root, exit silently —
        // the macrophage will not police repos it doesn't own. When a client
        // site becomes bluebook-backed, its repo joins the tracked paths
        // (future ClientSignOffMacrophage + tracked_repo_paths attribute).
        if let Some(ref root) = corpus_root_buf {
            let file_path_buf = std::path::Path::new(&file_path);
            if !file_path_buf.starts_with(root) {
                std::process::exit(0);
            }
        }

        let ext = file_path.rsplit('.').next().unwrap_or("");
        let complaint = format!(
            "bluebook-first violation : {} wrote .{} ({}). The macrophage expected a \
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
        eprintln!("[macrophage] {}", complaint);
        std::process::exit(2);
    }
    std::process::exit(0);
}

/// Detect whether a Bash command writes to a kernel-surface file.
/// Returns Some(path) when a write to .rb / .rs / .sh / .py is detected ;
/// None otherwise. Closes the bypass the cadence-primitive Phase 1b
/// agent flagged on 2026-05-02 — the antibody hook only matched Edit /
/// Write / MultiEdit tools, so the same edits routed through `bash -c
/// "python3 <<EOF\nopen('foo.rs', 'w').write(...)\nEOF"` slipped
/// through entirely.
///
/// Fast-path : if the command doesn't mention any kernel-surface
/// extension, return None immediately. Most bash invocations are
/// reads (git, grep, ls, find) ; we don't want macrophage overhead
/// on every shell call.
///
/// Patterns matched (each catches one canonical write shape) :
///   1. `> path.rs`           — stdout redirect to file
///   2. `>> path.rs`          — append redirect to file
///   3. `tee path.rs`         — tee redirect (with or without -a)
///   4. `cat > path.rs`       — heredoc-via-cat target
///   5. `python ... open('path.rs', 'w')` — python file write
///   6. `python ... write_text('path.rs')` — pathlib write
///   7. `sed -i ... path.rs`  — in-place sed edit
///   8. `awk -i inplace ... path.rs` — in-place awk edit
fn detect_bash_write_target(cmd: &str) -> Option<String> {
    // Fast-path : require ANY kernel-surface extension to even consider scanning.
    if !cmd.contains(".rb") && !cmd.contains(".rs")
        && !cmd.contains(".sh") && !cmd.contains(".py") {
        return None;
    }

    // Helper : check if a path looks kernel-surface.
    let is_kernel_surface = |path: &str| -> bool {
        path.ends_with(".rb") || path.ends_with(".rs")
            || path.ends_with(".sh") || path.ends_with(".py")
    };

    // Token-by-token scan over the command, tracking the last
    // "redirect-like" operator seen. When we see one and the next
    // non-flag token is a kernel-surface path, that's a write target.
    let bytes = cmd.as_bytes();
    let mut i = 0usize;
    while i < bytes.len() {
        let c = bytes[i] as char;

        // Skip strings (' or ") in the OUTER scan — but record the
        // path INSIDE the string if it's a write target. Python heredocs
        // and quoted paths both flow through here.
        if c == '\'' || c == '"' {
            let quote = c;
            let start = i + 1;
            i += 1;
            while i < bytes.len() && bytes[i] as char != quote {
                if bytes[i] as char == '\\' && i + 1 < bytes.len() { i += 1; }
                i += 1;
            }
            let inside = &cmd[start..i.min(cmd.len())];
            // Look for python-style file-write patterns inside the string.
            // open('path.rs', 'w') or write_text('path.rs') or
            // Path('path.rs').write_text(...).
            if let Some(target) = scan_python_write_in(inside) {
                return Some(target);
            }
            i += 1; // skip closing quote
            continue;
        }

        // Skip comments (# to end of line) outside strings.
        if c == '#' {
            while i < bytes.len() && bytes[i] as char != '\n' { i += 1; }
            continue;
        }

        // Redirect operators : > >> | tee | python ... heredoc.
        if c == '>' {
            // Skip the operator (one or two chars).
            let mut j = i + 1;
            if j < bytes.len() && bytes[j] as char == '>' { j += 1; }
            // Skip whitespace.
            while j < bytes.len() && (bytes[j] as char).is_whitespace() { j += 1; }
            // Read the next token (until whitespace, |, ;, &, <, >).
            let start = j;
            while j < bytes.len() {
                let ch = bytes[j] as char;
                if ch.is_whitespace() || ch == '|' || ch == ';' || ch == '&'
                    || ch == '<' || ch == '>' { break; }
                j += 1;
            }
            let target = &cmd[start..j];
            // Strip surrounding quotes if any.
            let target = target.trim_matches(|c| c == '\'' || c == '"');
            if !target.is_empty() && is_kernel_surface(target) {
                return Some(target.to_string());
            }
            i = j;
            continue;
        }

        i += 1;
    }

    // Word-level scan for tee, sed -i, awk -i inplace, and python heredocs
    // that we missed via string-scanning above. These all have a
    // "command name + flags + path" structure.
    //
    // 2026-05-02 false-positive heal : sed and awk both accept harmless
    // read-only flags (`sed -n` to suppress autoprint ; `awk -F` for
    // field separator). The previous "any flag activates write
    // detection" rule mis-fired on `sed -n '120,200p' foo.rs` and
    // similar reads. Tighten : sed only writes with `-i` /
    // `--in-place` ; awk only writes with `-i inplace`. tee remains
    // always-write. Each entry names the bigram(s) that mean "this is
    // a write" — None for always-write, Some(&[…]) for required
    // tokens (an OR over the entries). For multi-token write
    // signatures (`awk -i inplace`), both tokens must appear in the
    // command string before path scanning starts.
    let scans: &[(&str, Option<&[&[&str]]>)] = &[
        ("tee", None),
        ("sed", Some(&[&["-i"][..], &["--in-place"][..]])),
        ("awk", Some(&[&["-i", "inplace"][..]])),
    ];
    for (cmd_name, write_signatures) in scans {
        if let Some(target) = scan_command_with_path_arg(cmd, cmd_name, *write_signatures) {
            return Some(target);
        }
    }

    None
}

/// Scan a string for Python write patterns : `open('path', 'w')` or
/// `write_text('path')` or `Path('path').write_text(...)`.
fn scan_python_write_in(s: &str) -> Option<String> {
    // open('path', 'w' | 'a' | 'wb') — naïve match
    let mut idx = 0;
    while let Some(pos) = s[idx..].find("open(") {
        let p = idx + pos + "open(".len();
        // Read the first quoted string (path).
        let path = read_quoted_after(&s[p..])?;
        // Look for ", 'w'" or ", 'a'" within ~30 chars after.
        let after = &s[p..];
        let lookahead = &after[..after.len().min(60)];
        if lookahead.contains(",'w") || lookahead.contains(",\"w")
            || lookahead.contains(", 'w") || lookahead.contains(", \"w")
            || lookahead.contains(",'a") || lookahead.contains(", 'a")
            || lookahead.contains(",\"a") || lookahead.contains(", \"a") {
            if !path.is_empty() && (path.ends_with(".rb") || path.ends_with(".rs")
                || path.ends_with(".sh") || path.ends_with(".py")) {
                return Some(path);
            }
        }
        idx = p;
    }
    None
}

fn read_quoted_after(s: &str) -> Option<String> {
    let bytes = s.as_bytes();
    let mut i = 0;
    while i < bytes.len() && (bytes[i] as char).is_whitespace() { i += 1; }
    if i >= bytes.len() { return None; }
    let q = bytes[i] as char;
    if q != '\'' && q != '"' { return None; }
    let start = i + 1;
    let mut j = start;
    while j < bytes.len() && bytes[j] as char != q {
        if bytes[j] as char == '\\' && j + 1 < bytes.len() { j += 1; }
        j += 1;
    }
    Some(s[start..j].to_string())
}

/// Find `needle` in `cmd`, but skip occurrences inside single- or
/// double-quoted regions (heredoc bodies, here-strings, embedded
/// scripts that mention paths as documentation). Walks the command
/// character-by-character ; toggles a quote-state on `'` and `"`
/// (respecting `\\\"` escapes) and only reports matches outside.
///
/// Used by scan_command_with_path_arg so a command like
/// `gh pr create --body "...tee rust/src/main.rs..."` doesn't
/// trigger the write classifier on its documentation text.
fn find_outside_quotes(cmd: &str, needle: &str) -> Option<usize> {
    if needle.is_empty() { return Some(0); }
    let bytes = cmd.as_bytes();
    let mut i = 0usize;
    let mut in_quote: Option<u8> = None;
    while i < bytes.len() {
        let c = bytes[i];
        match in_quote {
            Some(q) => {
                if c == b'\\' && i + 1 < bytes.len() { i += 2; continue; }
                if c == q { in_quote = None; }
                i += 1;
            }
            None => {
                if c == b'\'' || c == b'"' { in_quote = Some(c); i += 1; continue; }
                if cmd[i..].starts_with(needle) {
                    return Some(i);
                }
                i += 1;
            }
        }
    }
    None
}

/// Scan a bash command for `<cmd_name> [flags] path.{rb,rs,sh,py}` —
/// catches `tee path.rs`, `sed -i 's/foo/bar/' path.sh`, and similar.
///
/// `write_signatures` declares which token sequences mean "this is a
/// write" :
///   - `None` — the command is always a write (e.g. tee).
///   - `Some(&[&["-i"], &["--in-place"]])` — any of the inner sequences
///     present in the post-command-name token stream activates path
///     scanning. Each sequence is a list of consecutive tokens (a
///     bigram like `["-i", "inplace"]` requires both tokens to appear
///     consecutively).
///
/// 2026-05-02 false-positive heal : prior signature was a single
/// `flag_required: bool` ; "any flag activates" mis-classified
/// `sed -n '120,200p' foo.rs` (read-only print) as a write. The new
/// shape lets each cmd_name name the exact tokens that mean write.
fn scan_command_with_path_arg(
    cmd: &str,
    cmd_name: &str,
    write_signatures: Option<&[&[&str]]>,
) -> Option<String> {
    // Find the command name as a word boundary, OUTSIDE any quoted
    // region. The outer detect_bash_write_target scan already skips
    // string literals when looking for redirects ; this word-level
    // scan needs the same discipline. Without it, a Bash command
    // like `gh pr create --body "...tee rust/src/main.rs..."` (the
    // tee mention is inside a heredoc body) trips the classifier
    // even though no actual write is happening. 2026-05-02 false-
    // positive heal, follow-on to the sed-n fix.
    let needle = format!("{} ", cmd_name);
    let pos = match find_outside_quotes(cmd, &needle) {
        Some(p) => p,
        None => return None,
    };
    let after = &cmd[pos + needle.len()..];
    let tokens: Vec<&str> = after.split_whitespace()
        .take_while(|t| *t != "|" && *t != ";" && *t != "&&" && *t != "||")
        .collect();

    // Decide whether the post-command token stream contains a write
    // signature. None means "always a write". Some means "scan for one
    // of the bigrams ; if absent, the command is a read".
    let is_write = match write_signatures {
        None => true,
        Some(sigs) => sigs.iter().any(|sig| {
            // Bigram match : every token in sig must appear in tokens
            // consecutively, in order. Empty sig matches always.
            if sig.is_empty() { return true; }
            tokens.windows(sig.len()).any(|window| {
                window.iter().zip(sig.iter()).all(|(t, s)| t == s)
            })
        }),
    };
    if !is_write {
        return None;
    }

    for token in &tokens {
        if token.starts_with("-") {
            continue;
        }
        // Strip quotes.
        let path = token.trim_matches(|c| c == '\'' || c == '"');
        if path.ends_with(".rb") || path.ends_with(".rs")
            || path.ends_with(".sh") || path.ends_with(".py") {
            return Some(path.to_string());
        }
    }
    None
}

/// Scan a shell file for direct heki writes (heki append / upsert /
/// delete / mark) that lack `--reason`. Returns Some(violations) when
/// the file has at least one unreasoned write — the macrophage refuses
/// the edit. Returns None when the file is clean (no writes, or every
/// write carries --reason in its multi-line invocation).
///
/// Scanning rule : find each line that matches `heki (append|upsert|
/// delete|mark)` ; gather that line plus all bash-continuation lines
/// (each ending with `\`) ; check if --reason appears anywhere across
/// the joined invocation. Comments (`# heki append ...`) are skipped.
fn unreasoned_heki_writes(file_path: &str) -> Option<Vec<String>> {
    let source = std::fs::read_to_string(file_path).ok()?;
    let lines: Vec<&str> = source.lines().collect();
    let mut violations: Vec<String> = Vec::new();
    let mut i = 0;
    while i < lines.len() {
        let line = lines[i];
        let trimmed = line.trim_start();
        // Skip comments and shebangs ; only flag executable lines.
        if trimmed.starts_with('#') || trimmed.starts_with("//") {
            i += 1; continue;
        }
        // Match `heki append`, `heki upsert`, `heki delete`, `heki mark`.
        // Allow `$HECKS heki ...` or `"$HECKS" heki ...` or bare path.
        let is_write = ["heki append", "heki upsert", "heki delete", "heki mark"]
            .iter().any(|verb| line.contains(verb));
        if !is_write {
            i += 1; continue;
        }
        // Collect this line plus continuation lines (those ending with `\`
        // after stripping trailing whitespace). The continuation forms the
        // full invocation surface where --reason might appear.
        let mut joined = String::from(line);
        let mut j = i;
        while j < lines.len() && lines[j].trim_end().ends_with('\\') {
            j += 1;
            if j < lines.len() {
                joined.push(' ');
                joined.push_str(lines[j]);
            }
        }
        if !joined.contains("--reason") {
            // Trim the joined invocation for the diagnostic so it's
            // readable but bounded (~120 chars).
            let display: String = joined.split_whitespace()
                .collect::<Vec<_>>().join(" ");
            let display_short = if display.len() > 120 {
                format!("{}…", &display[..120])
            } else { display };
            violations.push(format!("line {}: {}", i + 1, display_short));
        }
        i = j + 1;
    }
    if violations.is_empty() { None } else { Some(violations) }
}

/// IR-query lookup for an imperative file (i122). Resolves the
/// corpus root (the `hecks_conception/` dir, parent of aggregates/)
/// and asks `dispatch_query::is_dispatched_by_corpus` whether
/// anything in the IR claims this file. When `Some`, the antibody
/// can exempt the edit structurally — the registry is no longer the
/// source of truth.
///
/// Cheap-ish: the specializer-target arm is a static array match ;
/// the hecksagon arm walks `*.hecksagon` files under the corpus root
/// (parses each on first match). Scoped to one process invocation.
fn dispatch_lookup(file_path: &str) -> Option<storehouse::dispatch_query::DispatchInfo> {
    let agg_dir = resolve_aggregates_dir()?;
    let corpus_root = std::path::Path::new(&agg_dir).parent()?;
    storehouse::dispatch_query::is_dispatched_by_corpus(file_path, corpus_root)
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
    // and storehouse), not at hecks_conception itself.
    if let Ok(home) = env::var("HECKS_HOME") {
        let p = format!("{}/hecks_conception/aggregates", home);
        if std::path::Path::new(&p).is_dir() { return Some(p); }
    }
    // Walk up from the binary :
    //   /…/hecks/storehouse/target/release/storehouse
    //   .parent() = release
    //   .parent() = target
    //   .parent() = storehouse
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
        eprintln!("Usage: storehouse daemon <ensure|status|stop> <pidfile> [command...]");
        std::process::exit(1);
    });
    match action {
        "ensure" => daemon_ensure(&args[3..]),
        "status" => daemon_status(&args[3..]),
        "stop"   => daemon_stop(&args[3..]),
        _ => {
            eprintln!("Unknown daemon action: {}", action);
            eprintln!("Usage: storehouse daemon <ensure|status|stop> <pidfile> [command...]");
            std::process::exit(1);
        }
    }
}

fn daemon_ensure(rest: &[String]) {
    let pidfile = rest.first().map(|s| s.as_str()).unwrap_or_else(|| {
        eprintln!("Usage: storehouse daemon ensure <pidfile> <command> [args...]");
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
        eprintln!("Usage: storehouse daemon status <pidfile>");
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
        eprintln!("Usage: storehouse daemon stop <pidfile>");
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

#[cfg(target_family = "unix")]
fn pid_alive(pid: u32) -> bool {
    extern "C" { fn kill(pid: i32, sig: i32) -> i32; }
    unsafe { kill(pid as i32, 0) == 0 }
}

#[cfg(not(target_family = "unix"))]
fn pid_alive(_pid: u32) -> bool {
    // On non-unix targets (e.g. wasm32) there's no process model.
    false
}

#[cfg(target_family = "unix")]
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

#[cfg(not(target_family = "unix"))]
fn spawn_detached(_cmd: &str, _args: &[String]) -> std::io::Result<u32> {
    // On non-unix targets (e.g. wasm32) there's no process model ;
    // any caller that reaches here gets an Unsupported error.
    Err(std::io::Error::new(
        std::io::ErrorKind::Unsupported,
        "spawn_detached not available on this target (no process model)",
    ))
}

fn run_loop(args: &[String]) {
    // [antibody-exempt: rust/src/main.rs run_loop — extends the cadence
    //  primitive with multi-command rotation (i106) and gated cadence (i108).
    //  This IS the structural rewrite that lets breath / ultradian / sleep_cycle
    //  retire. Same i80 retirement contract as the rest of the loop / daemon /
    //  macrophage family. Net ~30 LoC.]
    //
    // Args layout : storehouse loop <target> <Cmd1[,Cmd2,...]> --every <dur>
    //               [--gate <heki-file>:<field>=<value>] [k=v ...]
    //
    // Multi-command rotation (i106) : if <Aggregate.Command> contains commas,
    // the loop rotates through the list one-per-tick. `Breath.Inhale,Breath.Exhale`
    // alternates inhale → exhale → inhale → exhale every tick.
    //
    // Gated cadence (i108) : `--gate <file.heki>:<field>=<value>` skips the
    // dispatch (but still sleeps) when the gate predicate is false. Used
    // by sleep_cycle to advance NREM/REM only while consciousness.state ==
    // sleeping.
    let target = args.get(2).map(|s| s.as_str()).unwrap_or_else(|| {
        eprintln!("Usage: storehouse loop <bluebook-or-dir> <Domain::Aggregate.Command[,Domain::Aggregate.Command2,...]> --every <duration> [--gate <file.heki>:<field>=<value>] [key=val ...]");
        std::process::exit(1);
    });
    let cmd_full = args.get(3).map(|s| s.as_str()).unwrap_or_else(|| {
        eprintln!("loop : missing <Domain::Aggregate.Command>");
        std::process::exit(1);
    });
    // i560 v2 follow-up — strict FQN gate on each comma-separated
    // entry of the rotation list. Mirrors the main dispatch gate so
    // `storehouse loop` rejects short forms with the same actionable
    // error.
    for entry in cmd_full.split(',').map(|s| s.trim()).filter(|s| !s.is_empty()) {
        require_fqn_dispatch_address("loop", entry);
    }
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

    // Multi-command rotation (i106). Split on commas. Each entry is a
    // full Domain::Aggregate.Command FQN — require_fqn_dispatch_address
    // above already guaranteed the `::`. i630 : do NOT truncate to the
    // bare command name. The old `.split('.').last()` dropped the
    // aggregate qualifier, so an ambiguous bare `Check`
    // (Inbox::Inbox.Check) resolved to the wrong aggregate's command
    // (the macrophage's BidirectionalAssociation.CheckRun). Pass the
    // FQN through unchanged ; command_dispatch::resolve honors it via
    // resolve_fully_qualified, exactly as the single-shot CLI path.
    let cmd_names: Vec<String> = cmd_full.split(',')
        .map(|s| s.trim())
        .filter(|s| !s.is_empty())
        .map(|s| s.to_string())
        .collect();
    if cmd_names.is_empty() {
        eprintln!("loop : empty command list '{}'", cmd_full);
        std::process::exit(1);
    }

    // Gate parsing (i108). --gate <file.heki>:<field>=<value> — when the
    // predicate is false, we sleep without dispatching. Format chosen to
    // avoid ambiguity with shell-quoting and the existing key=val attr
    // parser : `:` separates path from predicate, `=` separates field from
    // value. e.g. : --gate information/consciousness.heki:state=sleeping
    let gate: Option<(String, String, String)> = args.iter().position(|a| a == "--gate")
        .and_then(|i| args.get(i + 1))
        .and_then(|spec| {
            let (path, pred) = spec.split_once(':')?;
            let (field, value) = pred.split_once('=')?;
            Some((path.to_string(), field.to_string(), value.to_string()))
        });

    // Parse trailing key=val attrs, skipping the --every / --gate flags
    // and their values.
    let mut attrs: std::collections::HashMap<String, storehouse::runtime::Value> = Default::default();
    let mut i = 4;
    while i < args.len() {
        if args[i] == "--every" { i += 2; continue; }
        if args[i] == "--gate"  { i += 2; continue; }
        if args[i].starts_with("--") { i += 1; continue; }
        let mut parts = args[i].splitn(2, '=');
        if let (Some(k), Some(v)) = (parts.next(), parts.next()) {
            attrs.insert(k.to_string(), storehouse::runtime::Value::Str(v.to_string()));
        }
        i += 1;
    }

    if let Some((p, f, v)) = &gate {
        eprintln!(
            "[storehouse loop] {} every {:?} gated on {}:{}={} (Ctrl-C to stop)",
            cmd_full, every, p, f, v
        );
    } else {
        eprintln!(
            "[storehouse loop] {} every {:?} (Ctrl-C to stop)",
            cmd_full, every
        );
    }

    // Build the combined domain ONCE (parse all bluebooks in the target),
    // boot the runtime ONCE, then loop dispatching. This is the speedup
    // over the shell `while true ; do storehouse agg/ Cmd ; sleep N ; done`
    // pattern, which paid full parse + boot per iteration.
    let data_dir = find_world_heki_dir(target)
        .unwrap_or_else(|| format!("{}/data", target.trim_end_matches('/')));
    // i153 — i117 Round 4 nested aggregates into bounded-context
    // subdirs (body/, mind/, etc.) ; the previous flat read_dir
    // loaded zero bluebooks and left every body-cycle daemon (heart,
    // breath, ultradian, sleep_cycle) firing UnknownCommand silently.
    // load_combined_domain mirrors dispatch_hecksagon's recursive
    // walk so loop sees the full conception including subdirs.
    let (domain, hecksagons) = if std::path::Path::new(target).is_dir() {
        (load_combined_domain(target), load_all_hecksagons(target))
    } else {
        let source = fs::read_to_string(target).unwrap_or_else(|e| {
            eprintln!("Cannot read {}: {}", target, e); std::process::exit(1);
        });
        (parser::parse(&source), Vec::new())
    };

    // gap3 (i220-3) — boot with hecksagons + providers so the LLM
    // dispatcher's drain_policies hook resolves :llm adapters during the
    // PM cascade. Without this, run_loop's ProduceImage cascade would
    // dispatch fine but no :llm adapter would fire and text_fr / text_en
    // would never populate. Mirrors the dispatch_hecksagon path.
    let mut rt = Runtime::boot_with_hecksagons(domain, Some(data_dir), hecksagons);
    register_llm_providers(&mut rt, target);
    storehouse::world::attach::attach_world_servers(&mut rt, target);
    let mut idx: usize = 0;
    loop {
        let gate_open = match &gate {
            None => true,
            Some((path, field, expected)) => gate_predicate_holds(path, field, expected),
        };
        if gate_open {
            let cmd_name = &cmd_names[idx % cmd_names.len()];
            if let Err(e) = rt.dispatch(cmd_name, attrs.clone()) {
                eprintln!("[storehouse loop] dispatch error: {:?}", e);
            }
            idx = idx.wrapping_add(1);
        }
        std::thread::sleep(every);
    }
}

/// `storehouse run-loop <target> [--every <dur>]
///   [--emit <EventName:AggregateType:AggregateId>]...
///   [--bootstrap-if <Agg>.<field>=<expected>:<Event>:<EmitAggType>:<EmitAggId>]...
///   [--dispatch <Aggregate.Command>]... [k=v ...]`
///
/// Runtime daemon — boots a Runtime once, ticks at the configured
/// cadence, fires registered actions on each tick. Wires the new
/// LoopDriver in `runtime/loop_driver.rs` to the CLI ; defaults
/// produce a 1Hz "BodyPulse" emit, matching mindstream.sh's actual
/// real cadence.
///
/// `--emit X:Y:Z` injects a synthetic event into the runtime's bus
/// (drives PMs only, no command pipeline). `--dispatch Cmd` runs the
/// full command path. Multiple of each may be passed ; they fire in
/// declaration order each tick. Trailing `k=v` pairs become attrs
/// for `--dispatch` actions (shared across all dispatches in the tick,
/// matching `storehouse loop`'s convention).
///
/// `--bootstrap-if <Agg>.<field>=<expected>:<Event>:<EmitAggType>:<EmitAggId>`
/// (i223) is a one-shot first-tick predicate-and-emit. On the first
/// tick only, if the named aggregate's named field equals the
/// expected value, the daemon emits a synthetic event keyed by the
/// trailing triple. After the first tick the bootstrap is drained
/// (no replay). Closes the mind-pm-bootstrap-on-attentive-restart
/// gap : a daemon restarting while consciousness is already
/// `attentive` never sees a fresh `WokenUp`, so PMs that
/// `starts_on "WokenUp"` are stranded with no instance and the
/// wake handler is inert. Multiple bootstraps may be declared.
///
/// SIGTERM / SIGINT today : the daemon exits at the next tick boundary
/// (graceful) when the stop flag flips. Per-transition PM persistence
/// in drain_policies means hard-kill loses no PM state — the worst
/// case is replaying one tick's policy cascade. Signal-driven shutdown
/// is a follow-up (needs signal_hook ; the runtime is dep-light today).
fn run_pm_loop(args: &[String]) {
    use storehouse::runtime::loop_driver::{BootstrapEmit, LoopDriver, TickAction};

    let target = match args.get(2).map(|s| s.as_str()) {
        Some(t) => t,
        None => {
            eprintln!(
                "Usage: storehouse run-loop <bluebook-or-dir> \
                 [--every <duration>] \
                 [--emit <Event:AggType:AggId>]... \
                 [--bootstrap-if <Agg>.<field>=<expected>:<Event>:<EmitAggType>:<EmitAggId>]... \
                 [--dispatch <Domain::Aggregate.Command>]... \
                 [key=val ...]"
            );
            std::process::exit(1);
        }
    };

    let every_str = args.iter().position(|a| a == "--every")
        .and_then(|i| args.get(i + 1))
        .map(|s| s.as_str())
        .unwrap_or("1s");
    let interval = parse_loop_duration(every_str).unwrap_or_else(|| {
        eprintln!("run-loop : cannot parse --every '{}' (try 1s, 500ms, 2m)", every_str);
        std::process::exit(1);
    });

    // Collect emit + dispatch + bootstrap actions in argv order so a
    // user can declare multiple cadenced events, command dispatches,
    // and one-shot bootstraps in one run. Multi-value flag pattern :
    // repeat the flag.
    let mut emits: Vec<(String, String, String)> = Vec::new();
    let mut dispatches: Vec<String> = Vec::new();
    // i223 — predicate-gated first-tick emissions. Each entry :
    // (predicate_agg_type, predicate_field, expected_value,
    //  emit_event_name, emit_agg_type, emit_agg_id). The aggregate_id
    //  the predicate reads is `emit_agg_id` (the bootstrap targets
    //  one record at a time ; the tuple shape stays small).
    let mut bootstraps: Vec<(String, String, String, String, String, String)> = Vec::new();
    let mut attrs: std::collections::HashMap<String, storehouse::runtime::Value> = Default::default();
    let mut i = 3;
    while i < args.len() {
        match args[i].as_str() {
            "--every" => { i += 2; continue; }
            "--emit" => {
                if let Some(spec) = args.get(i + 1) {
                    let parts: Vec<&str> = spec.splitn(3, ':').collect();
                    if parts.len() == 3 {
                        emits.push((parts[0].into(), parts[1].into(), parts[2].into()));
                    } else {
                        eprintln!("run-loop : --emit needs Event:AggType:AggId, got '{}'", spec);
                        std::process::exit(1);
                    }
                }
                i += 2;
            }
            "--bootstrap-if" => {
                // i223 — parse <Agg>.<field>=<expected>:<Event>:<EmitAggType>:<EmitAggId>.
                // Two split phases : first split on ':' into 4 parts
                // (predicate, event_name, emit_agg_type, emit_agg_id),
                // then split the predicate on '=' (state lhs vs rhs)
                // and on '.' (aggregate vs field).
                if let Some(spec) = args.get(i + 1) {
                    let parts: Vec<&str> = spec.splitn(4, ':').collect();
                    if parts.len() != 4 {
                        eprintln!(
                            "run-loop : --bootstrap-if needs \
                             <Agg>.<field>=<expected>:<Event>:<EmitAggType>:<EmitAggId>, got '{}'",
                            spec
                        );
                        std::process::exit(1);
                    }
                    let predicate = parts[0];
                    let event_name = parts[1].to_string();
                    let emit_agg_type = parts[2].to_string();
                    let emit_agg_id = parts[3].to_string();
                    let (lhs, expected) = match predicate.split_once('=') {
                        Some(p) => p,
                        None => {
                            eprintln!(
                                "run-loop : --bootstrap-if predicate must contain '=', got '{}'",
                                predicate
                            );
                            std::process::exit(1);
                        }
                    };
                    let (agg_type, field) = match lhs.split_once('.') {
                        Some(p) => p,
                        None => {
                            eprintln!(
                                "run-loop : --bootstrap-if predicate lhs must be \
                                 <Aggregate>.<field>, got '{}'",
                                lhs
                            );
                            std::process::exit(1);
                        }
                    };
                    bootstraps.push((
                        agg_type.into(), field.into(), expected.into(),
                        event_name, emit_agg_type, emit_agg_id,
                    ));
                }
                i += 2;
            }
            "--dispatch" => {
                if let Some(c) = args.get(i + 1) {
                    // i560 v2 follow-up — gate each --dispatch
                    // address to FQN form (Domain::Aggregate.Command)
                    // so run-loop matches the main dispatch entry point.
                    require_fqn_dispatch_address("run-loop", c);
                    // i630 : keep the full FQN ; do not truncate to the
                    // bare command name (it dropped the aggregate
                    // qualifier and mis-resolved ambiguous commands).
                    dispatches.push(c.to_string());
                }
                i += 2;
            }
            s if s.starts_with("--") => { i += 1; }
            s => {
                if let Some((k, v)) = s.split_once('=') {
                    attrs.insert(k.into(), storehouse::runtime::Value::Str(v.into()));
                }
                i += 1;
            }
        }
    }

    // Default action when no --emit / --dispatch given : fire a 1Hz
    // BodyPulse synthetic event. This matches mindstream's actual
    // real cadence and lets PMs that subscribe to BodyPulse advance
    // out of the box. Override by passing explicit flags.
    if emits.is_empty() && dispatches.is_empty() {
        emits.push(("BodyPulse".into(), "Pulse".into(), "pulse".into()));
    }

    let data_dir = find_world_heki_dir(target)
        .unwrap_or_else(|| format!("{}/data", target.trim_end_matches('/')));
    let (domain, hecksagons) = if std::path::Path::new(target).is_dir() {
        (load_combined_domain(target), load_all_hecksagons(target))
    } else {
        let source = fs::read_to_string(target).unwrap_or_else(|e| {
            eprintln!("Cannot read {}: {}", target, e); std::process::exit(1);
        });
        (parser::parse(&source), Vec::new())
    };

    // gap3 (i220-3) — boot with hecksagons + providers so the LLM
    // dispatcher's drain_policies hook resolves :llm adapters during
    // PM-cascade dispatches. Same wiring as run_loop / dispatch_hecksagon.
    let mut rt = Runtime::boot_with_hecksagons(domain, Some(data_dir), hecksagons);
    register_llm_providers(&mut rt, target);
    storehouse::world::attach::attach_world_servers(&mut rt, target);
    let mut driver = LoopDriver::new(rt, interval);
    for (ev, ty, id) in emits {
        driver.add_emit(&ev, &ty, &id, std::collections::HashMap::new());
    }
    for cmd in dispatches {
        driver.add_action(TickAction::Dispatch {
            command_name: cmd,
            attrs: attrs.clone(),
        });
    }
    // i223 — register parsed bootstraps. The predicate aggregate_id is
    // the same as the emit aggregate_id for the canonical
    // Consciousness.state=attentive case ; if a future caller needs a
    // cross-aggregate predicate (read X to decide whether to emit on
    // Y), the CLI surface can grow a second `:` field. For today's
    // single-aggregate case, sharing keeps the surface terse.
    let bootstrap_count = bootstraps.len();
    for (agg_type, field, expected, event_name, emit_agg_type, emit_agg_id) in bootstraps {
        driver.add_bootstrap(BootstrapEmit {
            aggregate_type: agg_type,
            aggregate_id: emit_agg_id.clone(),
            field,
            expected,
            event: TickAction::Emit {
                event_name,
                aggregate_type: emit_agg_type,
                aggregate_id: emit_agg_id,
                data: std::collections::HashMap::new(),
            },
        });
    }
    eprintln!(
        "[storehouse run-loop] {} actions/tick every {:?} ({} bootstrap{}, Ctrl-C to stop)",
        driver.runtime().domain.name, interval, bootstrap_count,
        if bootstrap_count == 1 { "" } else { "s" }
    );
    driver.run();
}

/// Predicate for the --gate flag on `storehouse loop` (i108). Reads the
/// latest record from the named .heki store, looks up `field`, and
/// returns true iff its string form equals `expected`. Missing file,
/// missing field, or read errors all evaluate to false (gate closed) so
/// the gated loop is conservative — it only fires when the gate is
/// definitively open.
fn gate_predicate_holds(file: &str, field: &str, expected: &str) -> bool {
    let store = match heki::read(file) {
        Ok(s) => s,
        Err(_) => return false,
    };
    let rec = match heki::latest(&store) {
        Some(r) => r,
        None => return false,
    };
    let actual = heki_query::field_to_string(rec.get(field));
    actual == expected
}

/// Wall-clock segment trigger primitive (i107). Boots the runtime once,
/// polls every `--poll <dur>` (default 60s), and dispatches the
/// configured command for the current local-hour segment whenever the
/// segment changes. The first tick after boot always dispatches —
/// .heki state catches up if the daemon was down across a transition.
///
/// Args layout :
///   storehouse clock <target>
///     --segment <lo>-<hi>:<Aggregate.Command>   (one or more)
///     [--poll <duration>]                       (default 60s)
///
/// `lo`-`hi` are local-hour boundaries in [0,23]. Wrap-around supported
/// (`20-4` covers 20:00 through 04:59). First matching segment wins.
fn run_clock(args: &[String]) {
    let target = args.get(2).map(|s| s.as_str()).unwrap_or_else(|| {
        eprintln!("Usage: storehouse clock <bluebook-or-dir> --segment <lo>-<hi>:<Domain::Aggregate.Command> [--segment ...] [--poll <dur>]");
        std::process::exit(1);
    });

    // Collect every --segment <lo>-<hi>:<Aggregate.Command>. Order matters :
    // first match wins on overlap.
    let mut segments: Vec<(u32, u32, String)> = Vec::new();
    let mut i = 3;
    let mut poll = std::time::Duration::from_secs(60);
    while i < args.len() {
        match args[i].as_str() {
            "--segment" => {
                let spec = args.get(i + 1).map(|s| s.as_str()).unwrap_or_else(|| {
                    eprintln!("clock : --segment needs <lo>-<hi>:<Domain::Aggregate.Command>");
                    std::process::exit(1);
                });
                // i560 v2 — `lo-hi:Domain::Aggregate.Command` splits on
                // the FIRST ':' so the `::` inside the FQN address stays
                // intact for the trailing command field. splitn(2, ':')
                // gives `lo-hi` + `Domain::Aggregate.Command` ; without
                // it, the FQN would be torn at the first `::` colon.
                let (range, cmd_full) = match spec.splitn(2, ':').collect::<Vec<&str>>().as_slice() {
                    [r, c] => (*r, *c),
                    _ => {
                        eprintln!("clock : bad --segment '{}' (expected <lo>-<hi>:<Cmd>)", spec);
                        std::process::exit(1);
                    }
                };
                let (lo_s, hi_s) = range.split_once('-').unwrap_or_else(|| {
                    eprintln!("clock : bad hour-range '{}' (expected <lo>-<hi>)", range);
                    std::process::exit(1);
                });
                let lo: u32 = lo_s.parse().unwrap_or_else(|_| {
                    eprintln!("clock : bad lo hour '{}'", lo_s); std::process::exit(1);
                });
                let hi: u32 = hi_s.parse().unwrap_or_else(|_| {
                    eprintln!("clock : bad hi hour '{}'", hi_s); std::process::exit(1);
                });
                if lo > 23 || hi > 23 {
                    eprintln!("clock : hours must be 0..=23 (got {}-{})", lo, hi);
                    std::process::exit(1);
                }
                // i560 v2 follow-up — gate each --segment address to
                // FQN form (Domain::Aggregate.Command).
                require_fqn_dispatch_address("clock", cmd_full);
                // i630 : keep the full FQN. Truncating to the bare
                // command name dropped the aggregate qualifier and let
                // an ambiguous command resolve to the wrong aggregate.
                let cmd_name = cmd_full.to_string();
                segments.push((lo, hi, cmd_name));
                i += 2;
            }
            "--poll" => {
                let dur_s = args.get(i + 1).map(|s| s.as_str()).unwrap_or("60s");
                poll = parse_loop_duration(dur_s).unwrap_or_else(|| {
                    eprintln!("clock : cannot parse --poll '{}'", dur_s);
                    std::process::exit(1);
                });
                i += 2;
            }
            _ => i += 1,
        }
    }
    if segments.is_empty() {
        eprintln!("clock : need at least one --segment <lo>-<hi>:<Cmd>");
        std::process::exit(1);
    }

    eprintln!(
        "[storehouse clock] {} segments, polling every {:?} (Ctrl-C to stop)",
        segments.len(), poll
    );

    // Build domain + boot runtime ONCE — same shape as run_loop.
    // i153 — recursive walk so nested-context aggregates (body/, mind/,
    // etc.) are visible. Without this, the circadian segment trigger
    // dispatches against an empty domain and every clock dispatch
    // fires UnknownCommand silently.
    let data_dir = find_world_heki_dir(target)
        .unwrap_or_else(|| format!("{}/data", target.trim_end_matches('/')));
    let domain = if std::path::Path::new(target).is_dir() {
        load_combined_domain(target)
    } else {
        let source = fs::read_to_string(target).unwrap_or_else(|e| {
            eprintln!("Cannot read {}: {}", target, e); std::process::exit(1);
        });
        parser::parse(&source)
    };
    let mut rt = Runtime::boot_with_data_dir(domain, Some(data_dir));

    // Parse trailing key=val attrs (same pattern as run_loop)
    let mut clock_attrs: std::collections::HashMap<String, storehouse::runtime::Value> = Default::default();
    for arg in &args[3..] {
        if arg.starts_with("--") { continue; }
        let mut parts = arg.splitn(2, '=');
        if let (Some(k), Some(v)) = (parts.next(), parts.next()) {
            clock_attrs.insert(k.to_string(), storehouse::runtime::Value::Str(v.to_string()));
        }
    }

    let mut last_cmd: Option<String> = None;
    loop {
        let hour = current_local_hour();
        if let Some(cmd_name) = match_segment(&segments, hour) {
            if last_cmd.as_deref() != Some(cmd_name) {
                if let Err(e) = rt.dispatch(cmd_name, clock_attrs.clone()) {
                    eprintln!("[storehouse clock] dispatch error: {:?}", e);
                }
                last_cmd = Some(cmd_name.to_string());
            }
        }
        std::thread::sleep(poll);
    }
}

/// Returns local-time hour [0,23] without pulling chrono. Uses libc
/// localtime_r so DST behaves correctly.
fn current_local_hour() -> u32 {
    use std::time::{SystemTime, UNIX_EPOCH};
    let secs = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0);
    #[repr(C)]
    struct Tm {
        sec: i32, min: i32, hour: i32, mday: i32, mon: i32, year: i32,
        wday: i32, yday: i32, isdst: i32,
        gmtoff: i64, zone: *const i8,
    }
    extern "C" {
        fn localtime_r(time: *const i64, tm: *mut Tm) -> *mut Tm;
    }
    let mut tm = Tm {
        sec: 0, min: 0, hour: 0, mday: 0, mon: 0, year: 0,
        wday: 0, yday: 0, isdst: 0, gmtoff: 0, zone: std::ptr::null(),
    };
    unsafe { localtime_r(&secs, &mut tm); }
    tm.hour as u32
}

/// First-match-wins on the segments list. Wrap-around handled : if
/// `lo > hi`, the segment spans midnight (e.g. 20-4 = 20:00 through
/// 04:59).
fn match_segment<'a>(segs: &'a [(u32, u32, String)], hour: u32) -> Option<&'a str> {
    for (lo, hi, cmd) in segs {
        let in_range = if lo <= hi {
            hour >= *lo && hour <= *hi
        } else {
            hour >= *lo || hour <= *hi
        };
        if in_range {
            return Some(cmd.as_str());
        }
    }
    None
}

// ============================================================
// SLEEP SUBCOMMAND — blocking streaming-sleep CLI (i113)
// ============================================================
//
// Joins / starts a sleep session and streams stage transitions +
// dream impressions to stdout, then prints the wake report when
// the body wakes. One blocking command, one stream of state
// changes — the parent shell sees sleep happen.
//
// Resolution order :
//   1. If consciousness state is already "sleeping", join mid-flight
//      (no second EnterSleep dispatch).
//   2. Otherwise, dispatch Consciousness.EnterSleep through the
//      hecksagon and start polling.
//
// Stream contract :
//   [hh:mm]  <stage>  cycle <N>/<total>   [· <impression>]
//   [hh:mm]  lucid <stage>  cycle <N>     [· <observation>]
//   [hh:mm]  waking <mood>
//
// Each line is a state CHANGE (not every poll) — emitted once per
// new value of (sleep_stage, sleep_cycle, is_lucid, latest dream
// impression, latest lucid observation, state). stdout flushed
// after each emit.
//
// Exit codes :
//   0  clean wake (state left "sleeping")
//   1  30-min timeout without waking
fn run_sleep(_args: &[String]) {
    use std::io::Write;
    use std::time::Instant;

    // Resolve aggregates dir + heki dir the same way run_macrophage
    // does — HECKS_HOME, then walk up from the binary. The find_world_
    // heki_dir helper honors HECKS_INFO override, so private-state
    // setups (~/Projects/miette-state/information) keep working.
    let agg_dir = match resolve_aggregates_dir() {
        Some(p) => p,
        None    => {
            eprintln!("[sleep] cannot resolve aggregates dir (set HECKS_HOME)");
            std::process::exit(1);
        }
    };
    let info_dir = find_world_heki_dir(&agg_dir).unwrap_or_else(|| {
        // Best-effort fallback : sibling `information/` of aggregates
        std::path::Path::new(&agg_dir).parent()
            .map(|p| p.join("information").to_string_lossy().into_owned())
            .unwrap_or_else(|| format!("{}/information", agg_dir))
    });
    let consciousness_path = heki::path_for_lookup(&info_dir, "consciousness");
    let dream_state_path   = heki::path_for_lookup(&info_dir, "dream_state");
    let lucid_dream_path   = heki::path_for_lookup(&info_dir, "lucid_dream");

    let started = Instant::now();
    let stdout = std::io::stdout();
    let mut out = stdout.lock();

    // ---- Step 1 : dispatch EnterSleep unless already sleeping --------
    let already_sleeping = sleep_read_state(&consciousness_path) == Some("sleeping".into());
    if already_sleeping {
        let _ = writeln!(out, "[00:00]  joining mid-sleep");
    } else {
        let _ = writeln!(out, "[00:00]  dispatching EnterSleep");
        let _ = out.flush();
        // Pass the canonical name so the runtime's identified_by :name
        // lookup finds the existing aggregate instead of minting a fresh
        // UUID. The production daemon emits BodyPulse:Consciousness:
        // consciousness ; without :name here the EnterSleep dispatch
        // creates a parallel UUID-keyed instance and the phase machine
        // stalls because BodyPulse never reaches it. EnterSleep also
        // requires :sleep_at (ISO-8601 UTC) — same convention
        // CompleteFinalLight uses for :wake_at (i196).
        let mut attrs: std::collections::HashMap<String, serde_json::Value> =
            std::collections::HashMap::new();
        attrs.insert("name".into(),
                     serde_json::Value::String("consciousness".into()));
        attrs.insert("sleep_at".into(),
                     serde_json::Value::String(chrono_utc_now()));
        // Fire through the hecksagon — same path Daemon roles take.
        // catch_unwind so a dispatch failure (e.g. given clause refuses)
        // doesn't abort the streamer ; we'll see state stay non-sleeping
        // and exit 1 on timeout.
        let _ = std::panic::catch_unwind(|| {
            dispatch_hecksagon(&agg_dir, "EnterSleep", attrs);
        });
    }
    let _ = out.flush();

    // ---- Step 2 : poll loop, emit on change --------------------------
    let mut last_stage:    Option<String> = None;
    let mut last_cycle:    Option<i64>    = None;
    let mut last_lucid:    Option<String> = None;
    let mut last_dream_id: Option<String> = None;
    let mut last_lucid_id: Option<String> = None;
    let mut last_state:    Option<String> = None;

    loop {
        // 30-min timeout
        let elapsed = started.elapsed();
        if elapsed.as_secs() > 30 * 60 {
            let _ = writeln!(out, "[{}]  TIMEOUT — 30 min without wake",
                             sleep_fmt_elapsed(elapsed.as_secs()));
            let _ = out.flush();
            std::process::exit(1);
        }

        // -- consciousness.heki : state, sleep_stage, sleep_cycle, is_lucid
        let cons = storehouse::heki::read(&consciousness_path).ok()
            .and_then(|store| storehouse::heki::latest(&store).cloned());

        if let Some(rec) = &cons {
            let state = rec.get("state").and_then(|v| v.as_str())
                .unwrap_or("").to_string();
            let stage = rec.get("sleep_stage").and_then(|v| v.as_str())
                .unwrap_or("").to_string();
            let cycle = rec.get("sleep_cycle").and_then(|v| v.as_i64())
                .unwrap_or(0);
            let total = rec.get("sleep_total").and_then(|v| v.as_i64())
                .unwrap_or(0);
            let lucid = rec.get("is_lucid").and_then(|v| v.as_str())
                .unwrap_or("no").to_string();
            let summary = rec.get("sleep_summary").and_then(|v| v.as_str())
                .unwrap_or("").to_string();

            // Stage / cycle / lucid change → stream a stage line
            let stage_changed = last_stage.as_deref() != Some(stage.as_str());
            let cycle_changed = last_cycle != Some(cycle);
            let lucid_changed = last_lucid.as_deref() != Some(lucid.as_str());
            if (stage_changed || cycle_changed || lucid_changed)
                && !stage.is_empty() && state == "sleeping"
            {
                let prefix = if lucid == "yes" {
                    format!("lucid {}", stage)
                } else {
                    stage.clone()
                };
                let _ = writeln!(out, "[{}]  {:<10}  cycle {}/{}",
                                 sleep_fmt_elapsed(elapsed.as_secs()),
                                 prefix, cycle, total);
                let _ = out.flush();
                last_stage = Some(stage);
                last_cycle = Some(cycle);
                last_lucid = Some(lucid);
            }

            // State change to non-sleeping → break to wake-read
            if last_state.as_deref() != Some(state.as_str()) {
                if state != "sleeping" && state != "" && last_state.is_some() {
                    let suffix = if !summary.is_empty() {
                        format!("  ·  {}", sleep_truncate(&summary, 80))
                    } else {
                        String::new()
                    };
                    let _ = writeln!(out, "[{}]  waking {}{}",
                                     sleep_fmt_elapsed(elapsed.as_secs()),
                                     state, suffix);
                    let _ = out.flush();
                    break;
                }
                last_state = Some(state.clone());
            }

            // First-iteration check : if state was never "sleeping" at
            // poll-1 (EnterSleep refused, e.g. stuck in waking), don't
            // hang — break out.
            if last_state.as_deref() != Some("sleeping")
                && elapsed.as_secs() > 5
            {
                let _ = writeln!(out, "[{}]  state={} — never entered sleep, exiting",
                                 sleep_fmt_elapsed(elapsed.as_secs()),
                                 last_state.as_deref().unwrap_or(""));
                let _ = out.flush();
                std::process::exit(1);
            }
        }

        // -- dream_state.heki : latest impression text ---------------
        if let Ok(store) = storehouse::heki::read(&dream_state_path) {
            if let Some(rec) = storehouse::heki::latest(&store) {
                let id = rec.get("id").and_then(|v| v.as_str())
                    .unwrap_or("").to_string();
                if !id.is_empty() && last_dream_id.as_deref() != Some(id.as_str()) {
                    let text = sleep_pick_dream_text(rec);
                    if !text.is_empty() {
                        let _ = writeln!(out, "[{}]  dream  ·  {}",
                                         sleep_fmt_elapsed(elapsed.as_secs()),
                                         sleep_truncate(&text, 120));
                        let _ = out.flush();
                    }
                    last_dream_id = Some(id);
                }
            }
        }

        // -- lucid_dream.heki : latest narrative + observations ------
        if let Ok(store) = storehouse::heki::read(&lucid_dream_path) {
            if let Some(rec) = storehouse::heki::latest(&store) {
                let id = rec.get("id").and_then(|v| v.as_str())
                    .unwrap_or("").to_string();
                if !id.is_empty() && last_lucid_id.as_deref() != Some(id.as_str()) {
                    let narrative = rec.get("latest_narrative")
                        .and_then(|v| v.as_str()).unwrap_or("").to_string();
                    if !narrative.is_empty() {
                        let _ = writeln!(out, "[{}]  lucid  ·  {}",
                                         sleep_fmt_elapsed(elapsed.as_secs()),
                                         sleep_truncate(&narrative, 120));
                        let _ = out.flush();
                    }
                    last_lucid_id = Some(id);
                }
            }
        }

        std::thread::sleep(std::time::Duration::from_secs(1));
    }

    // ---- Step 3 : wait briefly for /tmp/wake_review_latest.md -------
    // The wake hook (wake_review.sh + interpret_dream.sh) fires
    // automatically on WokenUp ; give it ~5s to land before reading.
    let wake_path = "/tmp/wake_review_latest.md";
    let pre_mtime = sleep_file_mtime(wake_path);
    let wait_started = Instant::now();
    while wait_started.elapsed().as_secs() < 5 {
        let now_mtime = sleep_file_mtime(wake_path);
        if now_mtime != pre_mtime && now_mtime.is_some() {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(500));
    }

    if let Ok(contents) = fs::read_to_string(wake_path) {
        let _ = writeln!(out);
        let _ = writeln!(out, "── wake report ──");
        let _ = writeln!(out, "{}", contents);
        let _ = out.flush();
    } else {
        let _ = writeln!(out, "(no wake report at {})", wake_path);
        let _ = out.flush();
    }
}

/// Read the latest `state` field from consciousness.heki, if any.
fn sleep_read_state(path: &str) -> Option<String> {
    let store = storehouse::heki::read(path).ok()?;
    let rec = storehouse::heki::latest(&store)?;
    rec.get("state").and_then(|v| v.as_str()).map(|s| s.to_string())
}

/// Pick the human-readable dream text from a dream_state record.
/// Records may carry `english_translation`, `impression`, `text`, or
/// `french_image` (raw) — prefer the English variants if present.
fn sleep_pick_dream_text(rec: &storehouse::heki::Record) -> String {
    for key in ["english_translation", "english", "impression", "text",
                "translation", "french_image", "image"] {
        if let Some(s) = rec.get(key).and_then(|v| v.as_str()) {
            if !s.is_empty() { return s.to_string(); }
        }
    }
    String::new()
}

fn sleep_truncate(s: &str, max: usize) -> String {
    if s.chars().count() <= max { return s.to_string(); }
    let truncated: String = s.chars().take(max).collect();
    format!("{}…", truncated)
}

fn sleep_fmt_elapsed(secs: u64) -> String {
    let h = secs / 3600;
    let m = (secs % 3600) / 60;
    let s = secs % 60;
    if h > 0 {
        format!("{:02}:{:02}:{:02}", h, m, s)
    } else {
        format!("{:02}:{:02}", m, s)
    }
}

fn sleep_file_mtime(path: &str) -> Option<std::time::SystemTime> {
    fs::metadata(path).ok().and_then(|m| m.modified().ok())
}

/// Resolve the project home directory for a named being.
/// 1. HECKS_HOME env var
/// 2. ~/.hecks_home file (single line: path to hecks_conception)
/// 3. Follow symlink from the binary to storehouse/../hecks_conception
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
    // binary lives at storehouse/target/release/storehouse
    // project lives at hecks_conception (sibling of storehouse)
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

fn print_usage() {
    eprintln!("storehouse — the Bluebook compiler and runtime\n");
    eprintln!("Usage: storehouse <command> <bluebook-file> [options]\n");
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
    eprintln!("  loop       Cadence loop : dispatch one or more commands every <dur>");
    eprintln!("  clock      Wall-clock segment trigger : dispatch on local-hour transitions");
    eprintln!("  sleep      Dispatch EnterSleep, stream stage/dream changes, print wake report");
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

// ============================================================
// StoreHouse generic dispatcher (i484 ; main.rs shim).
//
// The hecks_conception/storehouse/{lexicon,dispatch,query}.bluebook
// trio is the contract ; this shim is the engine until i493 grows
// the four runtime pieces (bind directive, dotted templates, cross-
// aggregate auto-dispatch, walk-as-adapter) that let the storehouse
// hecksagons drive themselves. Living in main.rs (already kernel-
// surface exempt) keeps the new exempt surface at zero.
//
// Walk strategy mirrors run_boot/discover.rs : recurse the conception
// root for *.bluebook, parse each into the IR walker, build a phrase
// index keyed by Aggregate.Command + Domain.Aggregate.Command. The
// index lives in lexicon.heki for cheap subsequent lookups ; staleness
// is detected by comparing the newest *.bluebook mtime against the
// singleton row's compiled_at timestamp.
// ============================================================

fn run_storehouse(args: &[String]) -> i32 {
    let verb = args.get(2).map(|s| s.as_str()).unwrap_or("");
    let rest: &[String] = if args.len() > 3 { &args[3..] } else { &[] };
    match verb {
        "route"   => storehouse_route(rest),
        "compile" => storehouse_compile(rest),
        "read"    => storehouse_read(rest),
        "list"    => storehouse_list(rest),
        "lookup"  => storehouse_lookup(rest),
        "play"    => storehouse_play(rest),
        "" | "--help" | "-h" => {
            eprintln!("Usage: storehouse storehouse <verb> [args]\n");
            eprintln!("Verbs:");
            eprintln!("  route   <phrase> [k=v ...]   Dispatch.Route — invoke the bluebook owning <phrase>");
            eprintln!("  compile [conception_root]    Lexicon.Compile — rebuild lexicon.heki");
            eprintln!("  read    <Aggregate.attribute> Query.Read — project attribute from heki");
            eprintln!("  list    [filter]             Lexicon.List — browse phrases (substring filter)");
            eprintln!("  lookup  <phrase>             Lexicon.Lookup — print resolved target as JSON");
            eprintln!("  play    <story_id>           Story.Run — dispatch a Story's mapped steps in order");
            1
        }
        other => {
            eprintln!("storehouse storehouse: unknown verb '{}' (try --help)", other);
            1
        }
    }
}

#[derive(Debug, Clone)]
struct StorehousePhrase {
    phrase: String,
    domain_phrase: String,
    bluebook_path: String,
    aggregate: String,
    command: String,
}

fn storehouse_route(args: &[String]) -> i32 {
    let phrase = match args.first() {
        Some(p) => p.clone(),
        None => { eprintln!("storehouse storehouse route: missing phrase"); return 1; }
    };
    // A query-tail phrase (snake_case tail, e.g. `Plan::Story.by_sprint`)
    // can't resolve through the command lexicon — route it through the
    // read-only query path so query steps run from the CLI too. Mirrors
    // storehouse_router::route (GAP 3 — usecase-query-steps).
    if storehouse::storehouse_query::is_query_phrase(&phrase) {
        return storehouse::storehouse_query::query_route(&phrase, &args[1..]);
    }
    let conception = storehouse_conception_root();
    let target = match storehouse_resolve(&phrase, &conception) {
        Some(t) => t,
        None => {
            eprintln!("storehouse storehouse route: phrase '{}' not found in lexicon", phrase);
            return 4;
        }
    };
    // Synthesize the run::run_script argv : [storehouse, run, <bluebook>,
    // entrypoint=<command>, ...passthrough_args]. We pass the BARE command
    // name (not Aggregate.Command) because runtime/mod.rs's breadcrumb
    // writer prepends aggregate_type. Passing dotted produced doubled
    // prefixes ("WakeReview.WakeReview.ComposeWakeReview") on the status
    // bar. The runtime's command resolver accepts bare names ; ambiguity
    // (same command on multiple aggregates within one bluebook) doesn't
    // arise here because Lookup already pinned one specific aggregate.
    let mut run_args: Vec<String> = vec![
        "storehouse".to_string(),
        "run".to_string(),
        target.bluebook_path.clone(),
        format!("entrypoint={}", target.command),
    ];
    // Pass through every arg after the phrase as additional key=val attrs.
    for a in args.iter().skip(1) {
        run_args.push(a.clone());
    }
    // Telemetry is opt-in. The wake review surface is what Chris reads ;
    // the dispatch lines are debug noise on the success path. Failures
    // still print (run_script's own stderr) so a broken Route stays
    // visible. `HECKS_STOREHOUSE_VERBOSE=1` brings the lines back.
    let verbose = std::env::var("HECKS_STOREHOUSE_VERBOSE").ok().as_deref() == Some("1");
    if verbose {
        eprintln!("[storehouse] Dispatch.Route → {} ({})", target.phrase, target.bluebook_path);
    }
    let exit = storehouse::run::run_script(&run_args);
    if exit == 0 && verbose {
        eprintln!("[storehouse] Dispatched");
    }
    exit
}

/// Story.Run — execute a Story's mapped command sequence in order.
///
/// `storehouse storehouse play <story_id>` is the runtime projection of
/// the pure `Story.Run` bluebook command (see
/// hecks_conception/storehouse/story.bluebook). It is a SEPARATE runner
/// from the core dispatch loop : the dispatch of one Story is the
/// dispatch of its mapped commands, in order, each re-entering the bus
/// through the same `storehouse_resolve` + `run_script` machinery that
/// `storehouse_route` uses for a single phrase.
///
/// Flow :
///   1. Read the Story record back from its heki store.
///   2. Walk its `steps` list (a JSON array of {order, phrase, args}),
///      sort by `order` so call-order doesn't determine run-order.
///   3. For each step, unpack `args` (a JSON-object string) into k=v
///      tokens and dispatch the phrase via storehouse_route. If any step
///      fails (non-zero exit), stop and propagate — no partial-complete.
///   4. On full success, dispatch `Story.Run` with the step count so the
///      bluebook stamps the Story complete and emits StoryRan.
fn storehouse_play(args: &[String]) -> i32 {
    let story_id = match args.first() {
        Some(p) => p.clone(),
        None => { eprintln!("storehouse storehouse play: missing story_id"); return 1; }
    };
    let info_dir = match resolve_storehouse_info_dir() {
        Some(p) => p,
        None => { eprintln!("storehouse storehouse play: cannot resolve info dir"); return 3; }
    };
    let heki_path = storehouse::heki::path_for_lookup(&info_dir, "story");
    let store = match storehouse::heki::read(&heki_path) {
        Ok(s) => s,
        Err(e) => { eprintln!("storehouse storehouse play: {}", e); return 3; }
    };
    let record = match store.get(&story_id) {
        Some(r) => r,
        None => { eprintln!("storehouse storehouse play: no Story '{}' in {}", story_id, heki_path); return 4; }
    };
    let steps = story_sorted_steps(record);
    if steps.is_empty() {
        eprintln!("storehouse storehouse play: Story '{}' has no steps", story_id);
        return 4;
    }
    let total = steps.len();
    for (idx, step) in steps.iter().enumerate() {
        let mut route_args: Vec<String> = vec![step.phrase.clone()];
        route_args.extend(story_args_to_tokens(&step.args));
        eprintln!("[story:{}] step {}/{} → {}", story_id, idx + 1, total, step.phrase);
        let exit = storehouse_route(&route_args);
        if exit != 0 {
            eprintln!("[story:{}] step {}/{} ({}) failed (exit {}) — stopping", story_id, idx + 1, total, step.phrase, exit);
            return exit;
        }
    }
    // All steps ran. Flip the Story complete via the pure bluebook command.
    let run_args: Vec<String> = vec![
        "Story.Run".to_string(),
        format!("id={}", story_id),
        format!("step_count={}", total),
    ];
    storehouse_route(&run_args)
}

fn storehouse_compile(args: &[String]) -> i32 {
    let conception = args.first().cloned().unwrap_or_else(storehouse_conception_root);
    let phrases = storehouse_walk_phrases(&conception);
    let info_dir = match resolve_storehouse_info_dir() {
        Some(p) => p,
        None => { eprintln!("storehouse storehouse compile: cannot resolve info dir"); return 3; }
    };
    let lexicon_path = storehouse::heki::path_for_lookup(&info_dir, "lexicon");
    let now = storehouse::heki::now_iso();
    // Singleton row : lexicon (CompiledAt + PhraseCount).
    let mut singleton = storehouse::heki::Record::new();
    singleton.insert("id".into(), serde_json::Value::String("lexicon".into()));
    singleton.insert("compiled_at".into(), serde_json::Value::String(now.clone()));
    singleton.insert("phrase_count".into(),
        serde_json::Value::Number(serde_json::Number::from(phrases.len() as u64)));
    let _ = storehouse::heki::upsert(&lexicon_path, &singleton, storehouse::heki::WriteContext::OutOfBand {
        reason: "Lexicon.Compile singleton — CompiledAt + PhraseCount",
    });
    // One row per phrase. Idempotent on phrase id ; bluebook moves
    // overwrite the path field on the next compile.
    for p in &phrases {
        let mut rec = storehouse::heki::Record::new();
        rec.insert("id".into(), serde_json::Value::String(p.phrase.clone()));
        rec.insert("phrase".into(), serde_json::Value::String(p.phrase.clone()));
        rec.insert("domain_phrase".into(), serde_json::Value::String(p.domain_phrase.clone()));
        rec.insert("bluebook_path".into(), serde_json::Value::String(p.bluebook_path.clone()));
        rec.insert("aggregate".into(), serde_json::Value::String(p.aggregate.clone()));
        rec.insert("command".into(), serde_json::Value::String(p.command.clone()));
        rec.insert("compiled_at".into(), serde_json::Value::String(now.clone()));
        let _ = storehouse::heki::upsert(&lexicon_path, &rec, storehouse::heki::WriteContext::OutOfBand {
            reason: "Lexicon.Compile phrase row",
        });
    }
    println!("LexiconCompiled compiled_at={} phrase_count={} path={}",
        now, phrases.len(), lexicon_path);
    0
}

fn storehouse_read(args: &[String]) -> i32 {
    let path = match args.first() {
        Some(p) => p.clone(),
        None => { eprintln!("storehouse storehouse read: missing path"); return 1; }
    };
    let parts: Vec<&str> = path.split('.').collect();
    if parts.len() < 2 {
        eprintln!("storehouse storehouse read: path must be Aggregate.attribute");
        return 1;
    }
    let aggregate = parts[parts.len() - 2];
    let attribute = parts[parts.len() - 1];
    let info_dir = match resolve_storehouse_info_dir() {
        Some(p) => p,
        None => { eprintln!("storehouse storehouse read: cannot resolve info dir"); return 3; }
    };
    let snake = storehouse::heki::snake_case(aggregate);
    let heki_path = storehouse::heki::path_for_lookup(&info_dir, &snake);
    let store = match storehouse::heki::read(&heki_path) {
        Ok(s) => s,
        Err(e) => { eprintln!("storehouse storehouse read: {}", e); return 3; }
    };
    let latest = match storehouse::heki::latest(&store) {
        Some(r) => r,
        None => { eprintln!("storehouse storehouse read: no records in {}", heki_path); return 4; }
    };
    let value = match latest.get(attribute) {
        Some(serde_json::Value::String(s)) => s.clone(),
        Some(serde_json::Value::Number(n)) => n.to_string(),
        Some(serde_json::Value::Bool(b)) => b.to_string(),
        Some(other) => other.to_string(),
        None => { eprintln!("storehouse storehouse read: attribute '{}' not in {}", attribute, heki_path); return 4; }
    };
    println!("{}", value);
    0
}

fn storehouse_list(args: &[String]) -> i32 {
    let filter = args.first().map(|s| s.as_str()).unwrap_or("");
    let conception = storehouse_conception_root();
    let phrases = storehouse_walk_phrases(&conception);
    let mut shown = 0;
    for p in &phrases {
        if filter.is_empty() || p.phrase.contains(filter) || p.domain_phrase.contains(filter) {
            println!("{}\t{}", p.phrase, p.bluebook_path);
            shown += 1;
        }
    }
    if shown == 0 && !filter.is_empty() {
        eprintln!("(no matches for '{}'; total phrases: {})", filter, phrases.len());
    }
    0
}

fn storehouse_lookup(args: &[String]) -> i32 {
    let phrase = match args.first() {
        Some(p) => p.clone(),
        None => { eprintln!("storehouse storehouse lookup: missing phrase"); return 1; }
    };
    let conception = storehouse_conception_root();
    let target = match storehouse_resolve(&phrase, &conception) {
        Some(t) => t,
        None => {
            eprintln!("storehouse storehouse lookup: phrase '{}' not found", phrase);
            return 4;
        }
    };
    println!("{}", serde_json::json!({
        "phrase": target.phrase,
        "domain_phrase": target.domain_phrase,
        "bluebook_path": target.bluebook_path,
        "aggregate": target.aggregate,
        "command": target.command,
    }));
    0
}

/// Resolve a phrase to its target by walking the conception. Phrase forms :
///   "Aggregate.Command"           — two-segment, ambiguous if duplicated
///   "Domain.Aggregate.Command"    — three-segment, always specific
fn storehouse_resolve(phrase: &str, conception: &str) -> Option<StorehousePhrase> {
    let phrases = storehouse_walk_phrases(conception);
    // Normalize the canonical FQN Domain::Aggregate.Command (the runtime's
    // form, e.g. use-case step phrases) to the dotted Domain.Aggregate.Command
    // the lexicon stores as domain_phrase. Mirrors storehouse_router::resolve.
    let normalized = phrase.replace("::", ".");
    let segments: Vec<&str> = normalized.split('.').collect();
    if segments.len() == 2 {
        // Aggregate.Command — match against two-segment form
        phrases.into_iter().find(|p| p.phrase == normalized)
    } else if segments.len() == 3 {
        // Domain.Aggregate.Command — match against three-segment form
        phrases.into_iter().find(|p| p.domain_phrase == normalized)
    } else {
        None
    }
}

/// Walk every *.bluebook under the conception's bucket roots, parse
/// each into IR, extract every Aggregate.Command pair. Mirrors
/// run_boot/discover.rs's bucket list — recurse aggregates/, runtime/,
/// codegen/, cli/, integrations/, tools/, discipline/, storehouse/.
fn storehouse_walk_phrases(conception: &str) -> Vec<StorehousePhrase> {
    let root = std::path::Path::new(conception);
    let hecks_root = storehouse::heki::repo_root();
    let mut out = Vec::new();
    // hecks_conception/aggregates and hecks_conception/storehouse :
    storehouse_collect_recursive(&root.join("aggregates"), &mut out);
    storehouse_collect_recursive(&root.join("storehouse"), &mut out);
    // top-level repo buckets (i118 R3 W2) :
    if let Some(hroot) = hecks_root {
        for bucket in &["runtime", "codegen", "cli", "integrations", "tools", "discipline"] {
            storehouse_collect_recursive(&hroot.join(bucket), &mut out);
        }
    }
    out
}

fn storehouse_collect_recursive(dir: &std::path::Path, out: &mut Vec<StorehousePhrase>) {
    if !dir.is_dir() { return; }
    if let Ok(entries) = std::fs::read_dir(dir) {
        for entry in entries.flatten() {
            let p = entry.path();
            if p.is_dir() {
                storehouse_collect_recursive(&p, out);
            } else if p.extension().map(|e| e == "bluebook").unwrap_or(false) {
                if let Ok(src) = std::fs::read_to_string(&p) {
                    let domain = storehouse::parser::parse(&src);
                    if domain.name.is_empty() { continue; }
                    let path_str = p.to_string_lossy().into_owned();
                    // FQN phrases lead with the bluebook CATEGORY (e.g.
                    // "plan" → "Plan"), not its NAME ("Story"). See the
                    // identical fix in storehouse_router::collect_recursive.
                    let domain_seg = domain.category.as_deref()
                        .map(storehouse::storehouse_router::pascal_case_segments)
                        .unwrap_or_else(|| domain.name.clone());
                    for agg in &domain.aggregates {
                        for cmd in &agg.commands {
                            out.push(StorehousePhrase {
                                phrase: format!("{}.{}", agg.name, cmd.name),
                                domain_phrase: format!("{}.{}.{}", domain_seg, agg.name, cmd.name),
                                bluebook_path: path_str.clone(),
                                aggregate: agg.name.clone(),
                                command: cmd.name.clone(),
                            });
                        }
                    }
                }
            }
        }
    }
}

/// Detect whether a CLI token is an `Aggregate.Command` dispatch (e.g.
/// `Tools.Bash`, `Heartbeat.Beat`). Both segments must start uppercase ;
/// the second must be non-empty. Used by the cross-repo dispatch
/// shortcut at the top of `main` so callers can drop the explicit
/// conception path. Sibling commands like `Some.Thing.Else` (more than
/// one dot) still match — we just require the first dotted-pair to look
/// PascalCase on both sides.
fn looks_like_aggregate_command(s: &str) -> bool {
    let mut parts = s.splitn(2, '.');
    let head = match parts.next() { Some(h) => h, None => return false };
    let tail = match parts.next() { Some(t) => t, None => return false };
    if head.is_empty() || tail.is_empty() { return false; }
    if !head.chars().next().map_or(false, |c| c.is_ascii_uppercase()) { return false; }
    if !tail.chars().next().map_or(false, |c| c.is_ascii_uppercase()) { return false; }
    // Reject anything containing path separators — those are file paths.
    if s.contains('/') || s.contains('\\') { return false; }
    true
}

/// Resolve the conception root (the `hecks_conception/` directory).
///
/// Resolution order — cross-repo accessibility (i518 follow-up) :
///
///   1. `HECKS_CONCEPTION_DIR` env var when set and non-empty. Lets a
///      sibling project (`embryonaut-site`, `miette_family`, etc.) opt
///      into its own conception path without changing argv.
///   2. `repo_root()/hecks_conception/` when the canonicalised binary
///      lives inside the hecks checkout (the historical case).
///   3. `~/Projects/hecks/hecks_conception/` as a hard fallback so a
///      symlinked binary on PATH (`~/bin/storehouse` →
///      `~/Projects/hecks/rust/target/release/storehouse`) keeps
///      dispatching even when invoked from `cd /tmp` or any other
///      unrelated cwd. The `~` is expanded via the `$HOME` env var.
///   4. `.` when nothing above resolves (preserves the prior return
///      shape so existing callers don't observe a panic).
fn storehouse_conception_root() -> String {
    if let Ok(p) = env::var("HECKS_CONCEPTION_DIR") {
        if !p.is_empty() {
            return p;
        }
    }
    if let Some(root) = storehouse::heki::repo_root() {
        let conception = root.join("hecks_conception");
        if conception.is_dir() {
            return conception.to_string_lossy().into_owned();
        }
        return root.to_string_lossy().into_owned();
    }
    if let Ok(home) = env::var("HOME") {
        let fallback = format!("{}/Projects/hecks/hecks_conception", home);
        if std::path::Path::new(&fallback).is_dir() {
            return fallback;
        }
    }
    ".".into()
}

fn resolve_storehouse_info_dir() -> Option<String> {
    let canonical = storehouse::heki::resolve_info_dir();
    let s = canonical.to_string_lossy().into_owned();
    if canonical.exists() || s != "hecks_conception/information" {
        return Some(s);
    }
    None
}

/// Emits soft validator warnings to stderr — advisories, never failures.
///
/// Wires the four functions in `validator_warnings.rs` (the bluebook-declared
/// rules from `capabilities/validator_warnings_shape/`) into the dispatch arms
/// that touch a parsed Domain. Stays on stderr so parity tests and pipelines
/// keep reading clean stdout.
fn emit_validator_warnings_to_stderr(domain: &storehouse::ir::Domain) {
    if let Some(msg) = validator_warnings::aggregate_count_warning(domain)   { eprintln!("{}", msg); }
    if let Some(msg) = validator_warnings::multi_domain_split_warning(domain) { eprintln!("{}", msg); }
    if let Some(msg) = validator_warnings::mixed_concerns_warning(domain)    { eprintln!("{}", msg); }
    if let Some(msg) = validator_warnings::bluebook_size_warning(domain)     { eprintln!("{}", msg); }
}

/// Resolve the SubcommandRegistry heki path.
///
/// Resolves via HECKS_HOME or by walking up from the binary to the repo
/// root, then joins `hecks_conception/information/subcommand_registry/
/// subcommand.heki` — seeded by bin/seed-subcommand-registry from
/// cli/subcommand/subcommand.fixtures (domain SubcommandRegistry,
/// aggregate Subcommand, command Register).
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
