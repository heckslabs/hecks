
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
    let rest = &args[3..];
    match verb {
        "route"   => storehouse_route(rest),
        "compile" => storehouse_compile(rest),
        "read"    => storehouse_read(rest),
        "list"    => storehouse_list(rest),
        "lookup"  => storehouse_lookup(rest),
        "" | "--help" | "-h" => {
            eprintln!("Usage: storehouse storehouse <verb> [args]\n");
            eprintln!("Verbs:");
            eprintln!("  route   <phrase> [k=v ...]   Dispatch.Route — invoke the bluebook owning <phrase>");
            eprintln!("  compile [conception_root]    Lexicon.Compile — rebuild lexicon.heki");
            eprintln!("  read    <Aggregate.attribute> Query.Read — project attribute from heki");
            eprintln!("  list    [filter]             Lexicon.List — browse phrases (substring filter)");
            eprintln!("  lookup  <phrase>             Lexicon.Lookup — print resolved target as JSON");
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
