
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
            eprintln!("Usage: hecks-life storehouse <verb> [args]\n");
            eprintln!("Verbs:");
            eprintln!("  route   <phrase> [k=v ...]   Dispatch.Route — invoke the bluebook owning <phrase>");
            eprintln!("  compile [conception_root]    Lexicon.Compile — rebuild lexicon.heki");
            eprintln!("  read    <Aggregate.attribute> Query.Read — project attribute from heki");
            eprintln!("  list    [filter]             Lexicon.List — browse phrases (substring filter)");
            eprintln!("  lookup  <phrase>             Lexicon.Lookup — print resolved target as JSON");
            1
        }
        other => {
            eprintln!("hecks-life storehouse: unknown verb '{}' (try --help)", other);
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
        None => { eprintln!("hecks-life storehouse route: missing phrase"); return 1; }
    };
    let conception = storehouse_conception_root();
    let target = match storehouse_resolve(&phrase, &conception) {
        Some(t) => t,
        None => {
            eprintln!("hecks-life storehouse route: phrase '{}' not found in lexicon", phrase);
            return 4;
        }
    };
    // Synthesize the run::run_script argv : [hecks-life, run, <bluebook>,
    // entrypoint=<command>, ...passthrough_args]. We pass the BARE command
    // name (not Aggregate.Command) because runtime/mod.rs's breadcrumb
    // writer prepends aggregate_type. Passing dotted produced doubled
    // prefixes ("WakeReview.WakeReview.ComposeWakeReview") on the status
    // bar. The runtime's command resolver accepts bare names ; ambiguity
    // (same command on multiple aggregates within one bluebook) doesn't
    // arise here because Lookup already pinned one specific aggregate.
    let mut run_args: Vec<String> = vec![
        "hecks-life".to_string(),
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
    let exit = hecks_life::run::run_script(&run_args);
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
        None => { eprintln!("hecks-life storehouse compile: cannot resolve info dir"); return 3; }
    };
    let lexicon_path = hecks_life::heki::path_for_lookup(&info_dir, "lexicon");
    let now = hecks_life::heki::now_iso();
    // Singleton row : lexicon (CompiledAt + PhraseCount).
    let mut singleton = hecks_life::heki::Record::new();
    singleton.insert("id".into(), serde_json::Value::String("lexicon".into()));
    singleton.insert("compiled_at".into(), serde_json::Value::String(now.clone()));
    singleton.insert("phrase_count".into(),
        serde_json::Value::Number(serde_json::Number::from(phrases.len() as u64)));
    let _ = hecks_life::heki::upsert(&lexicon_path, &singleton, hecks_life::heki::WriteContext::OutOfBand {
        reason: "Lexicon.Compile singleton — CompiledAt + PhraseCount",
    });
    // One row per phrase. Idempotent on phrase id ; bluebook moves
    // overwrite the path field on the next compile.
    for p in &phrases {
        let mut rec = hecks_life::heki::Record::new();
        rec.insert("id".into(), serde_json::Value::String(p.phrase.clone()));
        rec.insert("phrase".into(), serde_json::Value::String(p.phrase.clone()));
        rec.insert("domain_phrase".into(), serde_json::Value::String(p.domain_phrase.clone()));
        rec.insert("bluebook_path".into(), serde_json::Value::String(p.bluebook_path.clone()));
        rec.insert("aggregate".into(), serde_json::Value::String(p.aggregate.clone()));
        rec.insert("command".into(), serde_json::Value::String(p.command.clone()));
        rec.insert("compiled_at".into(), serde_json::Value::String(now.clone()));
        let _ = hecks_life::heki::upsert(&lexicon_path, &rec, hecks_life::heki::WriteContext::OutOfBand {
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
        None => { eprintln!("hecks-life storehouse read: missing path"); return 1; }
    };
    let parts: Vec<&str> = path.split('.').collect();
    if parts.len() < 2 {
        eprintln!("hecks-life storehouse read: path must be Aggregate.attribute");
        return 1;
    }
    let aggregate = parts[parts.len() - 2];
    let attribute = parts[parts.len() - 1];
    let info_dir = match resolve_storehouse_info_dir() {
        Some(p) => p,
        None => { eprintln!("hecks-life storehouse read: cannot resolve info dir"); return 3; }
    };
    let snake = hecks_life::heki::snake_case(aggregate);
    let heki_path = hecks_life::heki::path_for_lookup(&info_dir, &snake);
    let store = match hecks_life::heki::read(&heki_path) {
        Ok(s) => s,
        Err(e) => { eprintln!("hecks-life storehouse read: {}", e); return 3; }
    };
    let latest = match hecks_life::heki::latest(&store) {
        Some(r) => r,
        None => { eprintln!("hecks-life storehouse read: no records in {}", heki_path); return 4; }
    };
    let value = match latest.get(attribute) {
        Some(serde_json::Value::String(s)) => s.clone(),
        Some(serde_json::Value::Number(n)) => n.to_string(),
        Some(serde_json::Value::Bool(b)) => b.to_string(),
        Some(other) => other.to_string(),
        None => { eprintln!("hecks-life storehouse read: attribute '{}' not in {}", attribute, heki_path); return 4; }
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
        None => { eprintln!("hecks-life storehouse lookup: missing phrase"); return 1; }
    };
    let conception = storehouse_conception_root();
    let target = match storehouse_resolve(&phrase, &conception) {
        Some(t) => t,
        None => {
            eprintln!("hecks-life storehouse lookup: phrase '{}' not found", phrase);
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
    let segments: Vec<&str> = phrase.split('.').collect();
    if segments.len() == 2 {
        // Aggregate.Command — match against two-segment form
        phrases.into_iter().find(|p| p.phrase == phrase)
    } else if segments.len() == 3 {
        // Domain.Aggregate.Command — match against three-segment form
        phrases.into_iter().find(|p| p.domain_phrase == phrase)
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
    let hecks_root = hecks_life::heki::repo_root();
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
                    let domain = hecks_life::parser::parse(&src);
                    if domain.name.is_empty() { continue; }
                    let path_str = p.to_string_lossy().into_owned();
                    for agg in &domain.aggregates {
                        for cmd in &agg.commands {
                            out.push(StorehousePhrase {
                                phrase: format!("{}.{}", agg.name, cmd.name),
                                domain_phrase: format!("{}.{}.{}", domain.name, agg.name, cmd.name),
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

fn storehouse_conception_root() -> String {
    if let Some(root) = hecks_life::heki::repo_root() {
        let conception = root.join("hecks_conception");
        if conception.is_dir() {
            return conception.to_string_lossy().into_owned();
        }
        return root.to_string_lossy().into_owned();
    }
    ".".into()
}

fn resolve_storehouse_info_dir() -> Option<String> {
    let canonical = hecks_life::heki::resolve_info_dir();
    let s = canonical.to_string_lossy().into_owned();
    if canonical.exists() || s != "hecks_conception/information" {
        return Some(s);
    }
    None
}
