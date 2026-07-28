//! Heki — Binary record storage
//!
//! [antibody-exempt: rust/src/heki.rs — kernel-floor binary
//!  record storage AND repo-root / info-dir path resolution. The
//!  bluebook DSL has no concept of "where to look for files" —
//!  this is the layer the loader uses BEFORE bluebooks can be
//!  parsed. `repo_root()` is public for load_combined_domain's
//!  sibling-walk to find `../miette/` robustly across worktree
//!  layouts. Retires when `heki.hecksagon` ships and storage
//!  operations dispatch through a `:fs` adapter binding (i521
//!  shipped heki.bluebook ; hecksagon side still pending).]
//!
//! Reads and writes .heki files: HEKI magic (4 bytes) + record count (u32 BE)
//! + zlib-compressed JSON. The JSON payload is a map of { id: String => record: Object }.
//!
//! Usage:
//!   let records = heki::read("information/mood.heki")?;
//!   heki::append("information/mood.heki", &attrs, WriteContext::Dispatch { ... })?;
//!   heki::upsert("information/mood.heki", &attrs, WriteContext::OutOfBand { reason: "..." })?;
//!
//! ## WriteContext discipline
//!
//! Every write carries a `WriteContext` so the audit trail can tell
//! the canonical path (a runtime command dispatch mutating its own
//! aggregate's heki) from out-of-band writes (test setup, manual
//! migration, bootstrap seed). The runtime's `Repository::save` /
//! `Repository::delete` always pass `Dispatch` ; CLI subcommands
//! (`storehouse heki upsert/delete/append`) require an explicit
//! `--reason "<why>"` flag and pass `OutOfBand`. Direct callers
//! without context are a discipline gap — that's the structural
//! enforcement test_purity_shape's audit channel will eventually
//! react to.

use std::collections::HashMap;
use std::fs;
use std::io::Read as IoRead;
use std::io::Write as IoWrite;
use std::path::Path;
use flate2::Compression;

/// A single record — a JSON object keyed by field name.
pub type Record = HashMap<String, serde_json::Value>;

/// A store — all records in one .heki file, keyed by ID.
pub type Store = HashMap<String, Record>;

/// Origin of a heki write — the discipline boundary. Every write
/// must declare which lane it's in. The runtime's command dispatcher
/// passes `Dispatch` ; CLI subcommands and tests pass `OutOfBand`
/// with a reason captured in the audit log.
#[derive(Debug, Clone, Copy)]
pub enum WriteContext<'a> {
    /// The canonical path : a runtime command applied a mutation,
    /// the dispatcher saved the resulting state. `aggregate` and
    /// `command` are recorded for the audit trail.
    Dispatch { aggregate: &'a str, command: &'a str },

    /// Out-of-band : the write didn't originate from a runtime
    /// dispatch. Legitimate cases are test setup, one-shot
    /// migration scripts, and bootstrap seeds. The `reason` is
    /// recorded so the audit dashboard can surface direct-write
    /// rate over time and flag patterns worth filing as runtime gaps.
    OutOfBand { reason: &'a str },
}

impl<'a> WriteContext<'a> {
    /// Format a one-line audit token for stderr / heki audit log.
    fn audit_tag(&self) -> String {
        match self {
            WriteContext::Dispatch { aggregate, command } =>
                format!("dispatch:{}.{}", aggregate, command),
            WriteContext::OutOfBand { reason } =>
                format!("out-of-band:{}", reason),
        }
    }
}

/// Audit channel — every write logs to stderr in a parseable form.
/// Quiet by default unless `HECKS_HEKI_AUDIT=1` is set ; out-of-band
/// writes always log so the discipline gap stays visible.
fn audit_write(ctx: &WriteContext, path: &str, op: &str) {
    let always = matches!(ctx, WriteContext::OutOfBand { .. });
    let verbose = std::env::var("HECKS_HEKI_AUDIT").ok().as_deref() == Some("1");
    if always || verbose {
        eprintln!("[heki:{}] {} → {}", op, ctx.audit_tag(), path);
    }
}

// ---------------------------------------------------------------------------
// Snapshot — backup before destructive ops
// ---------------------------------------------------------------------------

/// Snapshot a .heki file before a destructive operation. Copies
/// `<path>` to `<path's-dir>/.heki-snapshots/<basename>.<RFC3339>.heki`
/// before the caller's mutation. Idempotent : if the path doesn't
/// exist, returns Ok(None) ; if it does, returns Ok(Some(snapshot_path)).
/// Failures (permission, disk, etc.) bubble up as Err so callers can
/// decide whether to proceed.
///
/// Used by Repository auto-migration (mv flat → context-prefixed),
/// `delete()`, and any future destructive heki primitive. The
/// snapshots directory is gitignored ; users can clean it manually.
pub fn snapshot(path: &str) -> Result<Option<String>, String> {
    let src = Path::new(path);
    if !src.exists() {
        return Ok(None);
    }

    let parent = src.parent()
        .ok_or_else(|| format!("snapshot: cannot determine parent dir of {}", path))?;
    let basename = src.file_stem()
        .and_then(|s| s.to_str())
        .ok_or_else(|| format!("snapshot: cannot determine basename of {}", path))?;

    let snap_dir = parent.join(".heki-snapshots");
    fs::create_dir_all(&snap_dir)
        .map_err(|e| format!("snapshot: cannot create {}: {}", snap_dir.display(), e))?;

    // RFC3339 timestamp — reuse now_iso8601_internal which produces
    // YYYY-MM-DDTHH:MM:SSZ. Colons are filesystem-legal on macOS/Linux ;
    // keeping them preserves RFC3339 round-tripping.
    //
    // Collision case : two snapshots within the same second (rapid
    // back-to-back delete/mark) would clobber. Append `.N` until the
    // path is free so every call produces a distinct backup.
    let ts = crate::clock::now_iso8601_internal();
    let mut snap_path = snap_dir.join(format!("{}.{}.heki", basename, ts));
    let mut n = 1;
    while snap_path.exists() {
        snap_path = snap_dir.join(format!("{}.{}.{}.heki", basename, ts, n));
        n += 1;
    }

    fs::copy(src, &snap_path)
        .map_err(|e| format!("snapshot: copy {} → {}: {}",
            path, snap_path.display(), e))?;

    Ok(Some(snap_path.to_string_lossy().into_owned()))
}

// ---------------------------------------------------------------------------
// Read
// ---------------------------------------------------------------------------

/// Read a single .heki file into a Store. Returns empty store if file missing.
pub fn read(path: &str) -> Result<Store, String> {
    if !Path::new(path).exists() {
        return Ok(Store::new());
    }
    let data = fs::read(path).map_err(|e| format!("cannot read {}: {}", path, e))?;

    if data.len() < 8 {
        return Err(format!("{}: too short", path));
    }
    if &data[0..4] != b"HEKI" {
        return Err(format!("{}: bad magic", path));
    }

    let compressed = &data[8..];
    let mut decoder = flate2::read::ZlibDecoder::new(compressed);
    let mut json_str = String::new();
    decoder.read_to_string(&mut json_str)
        .map_err(|e| format!("{}: zlib error: {}", path, e))?;

    let store: Store = serde_json::from_str(&json_str)
        .map_err(|e| format!("{}: json error: {}", path, e))?;

    Ok(store)
}

/// Read all .heki files in a directory. Returns map of { name => Store }.
pub fn read_dir(dir: &str) -> Result<HashMap<String, Store>, String> {
    let path = Path::new(dir);
    if !path.is_dir() {
        return Err(format!("{}: not a directory", dir));
    }

    let mut all = HashMap::new();
    let mut entries: Vec<_> = fs::read_dir(path)
        .map_err(|e| format!("{}: {}", dir, e))?
        .filter_map(|e| e.ok())
        .filter(|e| e.path().extension().is_some_and(|ext| ext == "heki"))
        .collect();
    entries.sort_by_key(|e| e.file_name());

    for entry in entries {
        let file_path = entry.path();
        let name = file_path.file_stem()
            .and_then(|s| s.to_str())
            .unwrap_or("unknown")
            .to_string();
        match read(file_path.to_str().unwrap_or("")) {
            Ok(store) => { all.insert(name, store); }
            Err(e) => eprintln!("  skip: {}", e),
        }
    }

    Ok(all)
}

// ---------------------------------------------------------------------------
// Write
// ---------------------------------------------------------------------------

/// Fields that must never be persisted to disk, keyed by store name.
const REDACTED_FIELDS: &[(&str, &[&str])] = &[
    ("creator_auth", &["passcode"]),
];

/// Strip sensitive fields from a store before writing.
fn sanitize(path: &str, store: &Store) -> Store {
    let name = Path::new(path).file_stem()
        .and_then(|s| s.to_str()).unwrap_or("");
    let fields: Vec<&str> = REDACTED_FIELDS.iter()
        .filter(|(n, _)| *n == name)
        .flat_map(|(_, fs)| fs.iter().copied())
        .collect();
    if fields.is_empty() { return store.clone(); }
    let mut clean = store.clone();
    for rec in clean.values_mut() {
        for f in &fields { rec.remove(*f); }
    }
    clean
}

/// Write a store to a .heki file (HEKI + count + zlib-compressed JSON).
/// Public surface — all writes carry a `WriteContext` so the audit
/// channel can distinguish dispatch-driven persistence from out-of-band
/// rewrites. Internally calls `write_raw` after auditing.
pub fn write(path: &str, store: &Store, ctx: WriteContext<'_>) -> Result<(), String> {
    audit_write(&ctx, path, "persist");
    write_raw(path, store)
}

/// Persist a store to disk without auditing. Used by `append`, `upsert`,
/// `delete`, `archive` — those audit at their user-visible op level so
/// the log doesn't double-fire ("upsert" → "persist") for one logical
/// mutation. Not exposed outside this module.
fn write_raw(path: &str, store: &Store) -> Result<(), String> {
    let store = sanitize(path, store);
    let json = serde_json::to_string(&store)
        .map_err(|e| format!("json serialize: {}", e))?;

    let mut encoder = flate2::write::ZlibEncoder::new(Vec::new(), Compression::best());
    encoder.write_all(json.as_bytes())
        .map_err(|e| format!("zlib compress: {}", e))?;
    let compressed = encoder.finish()
        .map_err(|e| format!("zlib finish: {}", e))?;

    let count = store.len() as u32;
    let mut out = Vec::with_capacity(8 + compressed.len());
    out.extend_from_slice(b"HEKI");
    out.extend_from_slice(&count.to_be_bytes());
    out.extend_from_slice(&compressed);

    fs::write(path, &out).map_err(|e| format!("write {}: {}", path, e))
}

/// Append a new record with a generated UUID. Returns the new record.
pub fn append(path: &str, attrs: &Record, ctx: WriteContext<'_>) -> Result<Record, String> {
    audit_write(&ctx, path, "append");
    let mut store = read(path)?;
    let id = crate::util::uuid_v4();
    let now = crate::clock::now_iso8601_internal();

    let mut record = Record::new();
    record.insert("id".into(), serde_json::Value::String(id.clone()));
    record.insert("created_at".into(), serde_json::Value::String(now.clone()));
    record.insert("updated_at".into(), serde_json::Value::String(now));
    for (k, v) in attrs {
        record.insert(k.clone(), v.clone());
    }

    store.insert(id, record.clone());
    write_raw(path, &store)?;
    Ok(record)
}

/// Upsert a record.
///
/// Matching rules:
///   1. If attrs contains an `id` key AND the store already has a record
///      under that id, update that specific record.
///   2. Otherwise, if the store has exactly one record, update it
///      (singleton behavior — what census.heki, heartbeat.heki, and similar
///      singleton stores rely on).
///   3. Otherwise, create a new record with a fresh uuid (or the provided
///      `id` if given and not yet present).
///
/// Rule 1 is the fix for multi-record stores like inbox.heki where
/// `id=<existing-uuid>` used to arbitrarily update the first row instead
/// of the targeted one.
pub fn upsert(path: &str, attrs: &Record, ctx: WriteContext<'_>) -> Result<Record, String> {
    audit_write(&ctx, path, "upsert");
    let mut store = read(path)?;
    let now = crate::clock::now_iso8601_internal();

    // Rule 1: targeted update by explicit id.
    let explicit_id = attrs
        .get("id")
        .and_then(|v| v.as_str())
        .map(|s| s.to_string());
    if let Some(id) = &explicit_id {
        if let Some(existing) = store.get_mut(id) {
            for (k, v) in attrs {
                existing.insert(k.clone(), v.clone());
            }
            existing.insert("updated_at".into(), serde_json::Value::String(now));
            let rec = existing.clone();
            write_raw(path, &store)?;
            return Ok(rec);
        }
    }

    // Rule 2: singleton stores — update the sole record in place.
    if store.len() == 1 && explicit_id.is_none() {
        if let Some((_id, existing)) = store.iter_mut().next() {
            for (k, v) in attrs {
                existing.insert(k.clone(), v.clone());
            }
            existing.insert("updated_at".into(), serde_json::Value::String(now));
            let rec = existing.clone();
            write_raw(path, &store)?;
            return Ok(rec);
        }
    }

    // Rule 3: create. Reuse explicit id if the caller passed one that
    // didn't match — this preserves `id=1` style singletons that get
    // bootstrapped on first write.
    let id = explicit_id.unwrap_or_else(crate::util::uuid_v4);
    let mut rec = Record::new();
    rec.insert("id".into(), serde_json::Value::String(id.clone()));
    rec.insert("created_at".into(), serde_json::Value::String(now.clone()));
    rec.insert("updated_at".into(), serde_json::Value::String(now));
    for (k, v) in attrs {
        rec.insert(k.clone(), v.clone());
    }
    store.insert(id, rec.clone());
    write_raw(path, &store)?;
    Ok(rec)
}

/// Delete a record by ID. Returns true if found and removed.
pub fn delete(path: &str, id: &str, ctx: WriteContext<'_>) -> Result<bool, String> {
    audit_write(&ctx, path, "delete");
    let mut store = read(path)?;
    let removed = store.remove(id).is_some();
    if removed {
        write_raw(path, &store)?;
    }
    Ok(removed)
}

/// Archive a record — move it from source store to archive store.
/// Adds archived_at and archived_reason fields.
pub fn archive(source_path: &str, archive_path: &str, id: &str, reason: &str, ctx: WriteContext<'_>) -> Result<bool, String> {
    audit_write(&ctx, source_path, "archive");
    let mut store = read(source_path)?;
    if let Some(mut rec) = store.remove(id) {
        rec.insert("archived_reason".into(), serde_json::Value::String(reason.into()));
        rec.insert("archived_at".into(), serde_json::Value::String(crate::clock::now_iso8601_internal()));
        write_raw(source_path, &store)?;
        // Archive append uses the same context — semantically the
        // same operation.
        let mut store = read(archive_path)?;
        let id_val = rec.get("id").and_then(|v| v.as_str()).map(|s| s.to_string())
            .unwrap_or_else(crate::util::uuid_v4);
        store.insert(id_val, rec);
        write_raw(archive_path, &store)?;
        Ok(true)
    } else {
        Ok(false)
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Resolve a store name to a path: "mood" → "{dir}/mood.heki"
pub fn store_path(dir: &str, name: &str) -> String {
    Path::new(dir).join(format!("{}.heki", name)).to_string_lossy().into_owned()
}

// ---------------------------------------------------------------------------
// i145 — canonical heki path resolution
// ---------------------------------------------------------------------------
//
// Two callers shapes :
//
//   1. Writers (Repository, dispatch event log) know the aggregate's
//      context — pass it explicitly via [`path_for`]. i142 Tier 2
//      namespaces under `<dir>/<context_snake>/<aggregate_snake>.heki`.
//
//   2. Readers (statusline, status report, vitals, wake report,
//      sleep CLI, run_boot) often don't know the writer's context —
//      they have a name like "mood" or "tick". Use [`path_for_lookup`]
//      which tries the i142 nested form first (where post-i142
//      daemons write), falls back to the flat form (legacy
//      single-context corpora, or pre-i142 state).
//
// Single canonical home for path resolution prevents the dead-bar
// class of bug : Repository writes one shape, statusline reads another,
// silent staleness across consumers. Every path-builder in the codebase
// routes through these two functions.

/// Authoritative path for a write site that knows the aggregate's
/// context. When `context` is set (i142 Tier 2), returns the
/// nested form `<dir>/<context_snake>/<aggregate_snake>.heki`.
/// When `None`, returns the legacy flat form
/// `<dir>/<aggregate_snake>.heki`.
///
/// Used by Repository::heki_path_self.
pub fn path_for(dir: &str, aggregate: &str, context: Option<&str>) -> String {
    let agg_snake = crate::util::snake_case(aggregate);
    match context {
        Some(ctx) if !ctx.is_empty() => {
            let ctx_snake = crate::util::snake_case(ctx);
            format!("{}/{}/{}.heki", dir, ctx_snake, agg_snake)
        }
        _ => format!("{}/{}.heki", dir, agg_snake),
    }
}

/// Lookup path for a read site that doesn't know the writer's context.
///
/// Resolution order :
///
///   1. **Happy path** `<dir>/<name>/<name>.heki` — when bluebook
///      name == aggregate name (the common case). Single stat().
///   2. **Subdir scan** `<dir>/<context>/<name>.heki` — when bluebook
///      name ≠ aggregate name (28+ such bluebooks in the corpus today,
///      e.g. `Boot.bluebook` declares `BootRun` → file at
///      `boot/boot_run.heki`). Walks subdirs once, returns first hit.
///   3. **Flat fallback** `<dir>/<name>.heki` — pre-i142 corpora,
///      or aggregates whose Repository was constructed with no
///      context (legacy single-file callers).
///
/// The argument `name` should already be in the on-disk form
/// (lowercase, snake_case) — the function does NOT re-snake it.
/// Use this from statusline, status report, run_boot vitals, sleep
/// CLI, etc.
///
/// Returns the chosen path as a String for ergonomics with existing
/// callers that pass strings into `heki::read`. The chosen path is
/// always one of the candidates ; never an error.
pub fn path_for_lookup(dir: &str, name: &str) -> String {
    // 1. Happy path : context == aggregate name.
    let happy = format!("{}/{}/{}.heki", dir, name, name);
    if Path::new(&happy).exists() {
        return happy;
    }
    // 2. Subdir scan — handles context ≠ name (e.g. boot/boot_run.heki).
    //    One read_dir + one stat per immediate subdir ; bounded by the
    //    number of context dirs at the info root (~30 today).
    if let Ok(entries) = std::fs::read_dir(dir) {
        for entry in entries.flatten() {
            let p = entry.path();
            if p.is_dir() {
                let candidate = p.join(format!("{}.heki", name));
                if candidate.exists() {
                    return candidate.to_string_lossy().into_owned();
                }
            }
        }
    }
    // 3. Flat fallback — pre-i142 / no-context corpora.
    format!("{}/{}.heki", dir, name)
}

#[cfg(test)]
mod path_tests {
    use super::*;
    use std::fs;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn tempdir() -> std::path::PathBuf {
        // Unique per call: nanos can collide across parallel test threads
        // (same instant), so an atomic counter guarantees isolation and
        // kills the nested-vs-flat path-lookup race.
        use std::sync::atomic::{AtomicU64, Ordering};
        static SEQ: AtomicU64 = AtomicU64::new(0);
        let nanos = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let seq = SEQ.fetch_add(1, Ordering::Relaxed);
        let p = std::env::temp_dir().join(format!("heki_path_test_{}_{}", nanos, seq));
        fs::create_dir_all(&p).unwrap();
        p
    }

    #[test]
    fn walk_up_from_requires_aggregates_not_a_bare_hecks_conception() {
        // Regression (2026-06-22) : a stray information-only `hecks_conception/`
        // (no aggregates/) must NOT be mistaken for the repo root. An inner
        // ancestor carries a BARE hecks_conception/ ; an OUTER ancestor carries
        // the real hecks_conception/aggregates/. walk_up_from must skip the
        // stray and return the outer root (the old code stopped at the stray,
        // poisoning repo_root -> within_repo=false -> dead corpus-merge).
        let base = tempdir();
        let real_root = base.join("real");
        fs::create_dir_all(real_root.join("hecks_conception").join("aggregates")).unwrap();
        let stray = real_root.join("rust");
        fs::create_dir_all(stray.join("hecks_conception").join("information")).unwrap();
        let start = stray.join("target").join("release");
        fs::create_dir_all(&start).unwrap();

        assert_eq!(walk_up_from(&start), Some(real_root));

        let _ = fs::remove_dir_all(&base);
    }

    #[test]
    fn repo_root_from_conception_dir_returns_the_parent() {
        // Config-driven repo_root (decouple): HECKS_CONCEPTION_DIR -> its parent.
        let base = tempdir();
        let repo = base.join("a_repo");
        let conception = repo.join("hecks_conception");
        fs::create_dir_all(conception.join("aggregates")).unwrap();
        assert_eq!(
            repo_root_from_conception_dir(Some(conception.to_string_lossy().into_owned())),
            Some(repo.clone())
        );
        // Unset / empty / non-existent all fall through (None -> exe-walk).
        assert_eq!(repo_root_from_conception_dir(None), None);
        assert_eq!(repo_root_from_conception_dir(Some(String::new())), None);
        assert_eq!(
            repo_root_from_conception_dir(Some(base.join("nope").to_string_lossy().into_owned())),
            None
        );
        let _ = fs::remove_dir_all(&base);
    }

    #[test]
    fn config_conception_path_honors_xdg_then_home() {
        // XDG_CONFIG_HOME wins when set and non-empty.
        assert_eq!(
            config_conception_path_from(Some("/cfg".into()), Some("/home/u".into())),
            Some(std::path::PathBuf::from("/cfg/storehouse/conception"))
        );
        // Empty XDG falls back to ~/.config.
        assert_eq!(
            config_conception_path_from(Some(String::new()), Some("/home/u".into())),
            Some(std::path::PathBuf::from("/home/u/.config/storehouse/conception"))
        );
        // No XDG and no HOME -> None (no config dir to locate).
        assert_eq!(config_conception_path_from(None, None), None);
    }

    #[test]
    fn read_conception_config_trims_and_rejects_blank() {
        let dir = tempdir();
        let file = dir.join("conception");
        // Surrounding whitespace / trailing newline is trimmed.
        fs::write(&file, "  /Users/x/Projects/hecks/hecks_conception\n").unwrap();
        assert_eq!(
            read_conception_config(&file),
            Some("/Users/x/Projects/hecks/hecks_conception".to_string())
        );
        // Whitespace-only content -> None.
        fs::write(&file, "   \n").unwrap();
        assert_eq!(read_conception_config(&file), None);
        // Absent file -> None.
        assert_eq!(read_conception_config(&dir.join("missing")), None);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn path_for_with_context_emits_nested() {
        let p = path_for("/tmp/info", "Mood", Some("Body"));
        assert_eq!(p, "/tmp/info/body/mood.heki");
    }

    #[test]
    fn path_for_without_context_emits_flat() {
        let p = path_for("/tmp/info", "Mood", None);
        assert_eq!(p, "/tmp/info/mood.heki");
    }

    #[test]
    fn path_for_with_empty_context_emits_flat() {
        let p = path_for("/tmp/info", "Mood", Some(""));
        assert_eq!(p, "/tmp/info/mood.heki");
    }

    #[test]
    fn lookup_prefers_nested_when_it_exists() {
        // Write a nested file ; flat file doesn't exist.
        let dir = tempdir();
        let nested_dir = dir.join("mood");
        fs::create_dir_all(&nested_dir).unwrap();
        let nested_file = nested_dir.join("mood.heki");
        fs::write(&nested_file, "{}").unwrap();

        let chosen = path_for_lookup(&dir.to_string_lossy(), "mood");
        assert_eq!(chosen, format!("{}/mood/mood.heki", dir.display()));

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn lookup_falls_back_to_flat_when_nested_absent() {
        // Write only the flat file ; no nested dir.
        let dir = tempdir();
        let flat_file = dir.join("mood.heki");
        fs::write(&flat_file, "{}").unwrap();

        let chosen = path_for_lookup(&dir.to_string_lossy(), "mood");
        assert_eq!(chosen, format!("{}/mood.heki", dir.display()));

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn lookup_returns_flat_when_neither_exists() {
        // Neither nested nor flat exists. Returns flat (the historical
        // default) so heki::read fails predictably with "not found"
        // rather than reading whichever-happens-to-exist.
        let dir = tempdir();
        let chosen = path_for_lookup(&dir.to_string_lossy(), "nope");
        assert_eq!(chosen, format!("{}/nope.heki", dir.display()));
        let _ = fs::remove_dir_all(&dir);
    }

    /// The dead-bar invariant : Repository writes to `path_for(...)` ;
    /// every reader looking up the same aggregate via `path_for_lookup(...)`
    /// must find the same file. Catches the class of bug where one site
    /// writes to the nested form and another reads from the flat form.
    #[test]
    fn writer_and_reader_agree_on_nested_path() {
        let dir = tempdir();
        let writer_path = path_for(&dir.to_string_lossy(), "Mood", Some("Body"));
        // Writer creates the nested layout.
        if let Some(parent) = std::path::Path::new(&writer_path).parent() {
            fs::create_dir_all(parent).unwrap();
        }
        fs::write(&writer_path, "{}").unwrap();

        // Reader (with no context knowledge) finds the same file.
        let reader_path = path_for_lookup(&dir.to_string_lossy(), "mood");
        assert_eq!(writer_path, reader_path,
            "writer (path_for) and reader (path_for_lookup) must agree");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn writer_and_reader_agree_on_flat_path() {
        // Pre-i142 corpus : Repository declares no context, writes flat.
        // Reader finds the same flat file.
        let dir = tempdir();
        let writer_path = path_for(&dir.to_string_lossy(), "Mood", None);
        fs::write(&writer_path, "{}").unwrap();

        let reader_path = path_for_lookup(&dir.to_string_lossy(), "mood");
        assert_eq!(writer_path, reader_path,
            "writer (no context) and reader must both pick flat");
        let _ = fs::remove_dir_all(&dir);
    }
}

/// Walk up from `current_exe` to find the hecks repo root (the dir
/// containing `hecks_conception/`). Mirrors the heuristic used by
/// every body / runtime entry point. Returns None if we can't find
/// a hecks_conception/ within 6 ancestors.
///
/// Public — used by load_combined_domain to find the real hecks/
/// checkout when resolving the sibling `../miette/` root. Worktrees
/// nested under `.claude/worktrees/agent-XXX/` have their own
/// `hecks_conception/` copy ; relative-path math from a worktree's
/// agg_dir doesn't reach the real `~/Projects/miette/` because
/// `..` points inside `.claude/worktrees/`. Walking up from the
/// executable (which lives in the main checkout's
/// `storehouse/target/release/`) finds the canonical repo root.
pub fn repo_root() -> Option<std::path::PathBuf> {
    // Config-driven first (decouple Phase 1): HECKS_CONCEPTION_DIR names the
    // conception dir, whose PARENT is the repo root. This lets the engine
    // resolve the conception WITHOUT sitting beside it — the prerequisite for
    // storehouse living in its own repo. Additive + no-op while the env is
    // unset, so in-monorepo behaviour is unchanged ; the executable-walk
    // (walk_up_for_repo_root) is the transitional fallback.
    if let Some(root) = repo_root_from_conception_dir(std::env::var("HECKS_CONCEPTION_DIR").ok()) {
        return Some(root);
    }
    if let Some(root) = walk_up_for_repo_root() {
        return Some(root);
    }
    // Per-user config-file fallback : a PERSISTENT default for
    // HECKS_CONCEPTION_DIR. Post-extraction the engine binary lives OUTSIDE the
    // hecks tree, so the exe-walk finds nothing ; with HECKS_CONCEPTION_DIR
    // unset (a bare interactive shell — e.g. `storehouse follow`) repo_root was
    // None, which split readers onto a cwd-anchored store. A GENERIC engine
    // carries NO baked-in user path, so the canonical conception is NAMED in
    // ${XDG_CONFIG_HOME:-~/.config}/storehouse/conception — one file every
    // process tree reads identically (i728 : structural, not env-var).
    // repo_root_from_conception_dir guards with is_dir(), so an absent config
    // or a stale path falls through to None (CI without the file stays None).
    repo_root_from_conception_dir(config_conception_dir())
}

/// The repo root derived from a HECKS_CONCEPTION_DIR value — the conception
/// dir's PARENT. None when unset / empty / not a directory. Pure (the env
/// value is injected) so it is unit-testable without mutating the process
/// environment (which would race across parallel tests).
fn repo_root_from_conception_dir(env_val: Option<String>) -> Option<std::path::PathBuf> {
    let p = env_val.filter(|s| !s.is_empty())?;
    let conception = std::path::PathBuf::from(p);
    if conception.is_dir() {
        conception.parent().map(|x| x.to_path_buf())
    } else {
        None
    }
}

/// The conception dir named in the per-user config file
/// `${XDG_CONFIG_HOME:-~/.config}/storehouse/conception` (a single line : the
/// absolute path to a `hecks_conception` directory). The generic engine's
/// structural default — it carries NO user-specific path, reading the
/// deployment's conception location from config, the same value every process
/// tree reads (i728). None when the file is absent or blank.
fn config_conception_dir() -> Option<String> {
    read_conception_config(&config_conception_path()?)
}

/// Path to the storehouse conception config file, honoring XDG_CONFIG_HOME and
/// falling back to ~/.config — mirrors the `~/.config/<name>/` convention the
/// socket layer already uses (run_serve/socket.rs).
fn config_conception_path() -> Option<std::path::PathBuf> {
    config_conception_path_from(
        std::env::var("XDG_CONFIG_HOME").ok(),
        std::env::var("HOME").ok(),
    )
}

/// Pure path computation (env injected) so it is unit-testable without mutating
/// the process environment (which would race across parallel tests).
fn config_conception_path_from(
    xdg: Option<String>,
    home: Option<String>,
) -> Option<std::path::PathBuf> {
    let base = match xdg {
        Some(x) if !x.is_empty() => std::path::PathBuf::from(x),
        _ => std::path::PathBuf::from(home?).join(".config"),
    };
    Some(base.join("storehouse").join("conception"))
}

/// Read + trim a conception config file. None when missing or blank — pure over
/// the path so a temp file exercises it without env mutation.
fn read_conception_config(path: &std::path::Path) -> Option<String> {
    let raw = std::fs::read_to_string(path).ok()?;
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_string())
    }
}

fn walk_up_for_repo_root() -> Option<std::path::PathBuf> {
    let exe = std::env::current_exe().ok()?.canonicalize().ok()?;
    walk_up_from(exe.parent()?)
}

/// Walk up from `start` for the directory that contains a POPULATED
/// `hecks_conception/aggregates/` (the repo / conception root) - the
/// aggregates/ subdir distinguishes a real corpus root from a stray
/// information-only `hecks_conception/` dir - skipping any match inside a
/// `.claude/worktrees/` subtree. Shared by the binary-based resolution
/// (walk_up_for_repo_root, from current_exe) and the cwd-based resolution that
/// lets a test/story configure its own store by running from its OWN conception
/// (resolve_info_dir step 1) — the replacement for the removed HECKS_INFO redirect.
fn walk_up_from(start: &std::path::Path) -> Option<std::path::PathBuf> {
    let mut cur: std::path::PathBuf = start.to_path_buf();
    // Walk further than 6 to handle worktree-nested binaries : agent
    // worktrees live at .claude/worktrees/agent-XXX/rust/target/release/
    // which is 6 deep from the worktree root and 8 deep from the real
    // hecks repo root.
    for _ in 0..10 {
        // Require hecks_conception/aggregates/, not merely hecks_conception/ :
        // a stray information-only `hecks_conception/` dir (e.g. an accidental
        // `rust/hecks_conception/` written when a dispatch ran with a RELATIVE
        // agg_dir from the wrong cwd) carries no aggregates/ and must NOT be
        // mistaken for the repo root. That false match poisoned repo_root ->
        // within_repo=false -> the env corpus-merge AND framework buckets
        // silently stopped loading for every dispatch (root-caused 2026-06-22).
        if cur.join("hecks_conception").join("aggregates").is_dir() {
            // When running inside a Claude agent worktree, the worktree
            // has its own hecks_conception/ copy but is NOT the canonical
            // repo root — the sibling ../miette/ and ../miette_family/
            // checkouts only exist at the REAL hecks repo root, not
            // alongside the worktree dir. Skip the worktree match and
            // keep walking until we find a hecks_conception/ that's
            // outside any .claude/worktrees/ subtree.
            //
            // Detection : the worktree path contains ".claude/worktrees/"
            // somewhere in its ancestry. The real checkout doesn't.
            let s = cur.to_string_lossy();
            if !s.contains("/.claude/worktrees/") {
                return Some(cur);
            }
            // Otherwise fall through and keep walking.
        }
        let parent = cur.parent()?.to_path_buf();
        if parent == cur { break; }
        cur = parent;
    }
    None
}

// ---------------------------------------------------------------------------
// World-aware store resolution (realm + :default folder-derivation)
// ---------------------------------------------------------------------------
//
// The ONE resolver both the WRITER (main::find_world_heki_dir, the dispatch
// store path) and the READER (resolve_info_dir, used by statusline / run_wake /
// run_boot) consult, so readers and writers never split on where state lives.
// `.world` is the SINGLE source of the store location — HECKS_INFO is GONE.
// Env-var routing was the one thing that could split the writer from the reader
// (set in one launching env, unset in another) ; with it removed the world
// resolution is the only authority, so a :default/realm world simply IS where
// state lives, for writer and reader alike.

/// Expand a leading `~` / `~/` to `$HOME` ; non-tilde paths pass through.
pub fn expand_tilde(p: &str) -> String {
    if p == "~" {
        return std::env::var("HOME").unwrap_or_else(|_| p.to_string());
    }
    if let Some(rest) = p.strip_prefix("~/") {
        if let Ok(home) = std::env::var("HOME") {
            return format!("{}/{}", home.trim_end_matches('/'), rest);
        }
    }
    p.to_string()
}

/// Realm override resolution (presence-switch) : a nearby `.world` declaring
/// `realm "..."` makes its `heki.dir` authoritative, tilde-expanded, with the
/// snake-cased realm as the namespace dir. `<root>/<context>/<aggregate>.heki`
/// nests under it. `None` when no nearby world declares a realm.
// world::parser is wasm-gated (no .world parsing in the Worker) ; the wasm32
// sibling returns None so the heki-dir resolution chain is a structural no-op.
#[cfg(target_arch = "wasm32")]
pub fn resolve_realm_dir(_aggregates_path: &str) -> Option<String> { None }

#[cfg(not(target_arch = "wasm32"))]
pub fn resolve_realm_dir(aggregates_path: &str) -> Option<String> {
    use std::path::{Path, PathBuf};
    let agg = Path::new(aggregates_path);
    let base = if agg.is_dir() { agg } else { agg.parent()? };
    for dir in [Some(base), base.parent()].into_iter().flatten() {
        let entries = match std::fs::read_dir(dir) { Ok(e) => e, Err(_) => continue };
        let mut worlds: Vec<PathBuf> = entries
            .filter_map(|e| e.ok())
            .map(|e| e.path())
            .filter(|p| p.extension().is_some_and(|ext| ext == "world"))
            .collect();
        worlds.sort();
        for wf in worlds {
            let source = match std::fs::read_to_string(&wf) { Ok(s) => s, Err(_) => continue };
            let world = crate::world::parser::parse(&source);
            let realm = match &world.realm { Some(r) if !r.is_empty() => r, _ => continue };
            let dir_value = match world.config_for("heki").and_then(|c| c.get("dir")) {
                Some(d) => d, None => continue,
            };
            let root = Path::new(&expand_tilde(dir_value))
                .join(crate::util::snake_case(realm));
            std::fs::create_dir_all(&root).ok()?;
            return Some(root.to_string_lossy().into_owned());
        }
    }
    None
}

/// The OS-standard per-user data root — ask the OS, NEVER a custom override
/// (HECKS_DATA_DIR does not exist). macOS: ~/Library/Application Support/Hecks ;
/// Linux: $XDG_DATA_HOME or ~/.local/share/Hecks ; Windows: %APPDATA%\Hecks.
/// REPLACES the legacy per-user heki base — the realm folders (hecks/, miette/, …)
/// live under it. Reads only the OS's STANDARD data-dir env vars
/// ($XDG_DATA_HOME / $APPDATA / $HOME) — which IS asking the OS, not a
/// Hecks-specific override.
pub fn data_root() -> std::path::PathBuf {
    use std::path::PathBuf;
    let base: PathBuf = if cfg!(target_os = "macos") {
        std::env::var("HOME").ok()
            .map(|h| PathBuf::from(h).join("Library/Application Support"))
            .unwrap_or_else(|| PathBuf::from(expand_tilde("~/.local/share")))
    } else if cfg!(target_os = "windows") {
        std::env::var("APPDATA").ok().map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from(expand_tilde("~/AppData/Roaming")))
    } else {
        std::env::var("XDG_DATA_HOME").ok().map(PathBuf::from)
            .or_else(|| std::env::var("HOME").ok().map(|h| PathBuf::from(h).join(".local/share")))
            .unwrap_or_else(|| PathBuf::from(expand_tilde("~/.local/share")))
    };
    base.join("Hecks")
}

/// The store directory for an aggregate, anchored on its OWN realm rather than
/// the dispatching runtime's global `data_dir`. When the aggregate carries a
/// `realm_path` (`realm/context`, stamped from its bluebook's folder address)
/// AND the global store lives under the canonical `data_root()`, the store is
/// rooted at `data_root()/<realm>` — so a `miette` aggregate loaded as an
/// additional corpus root by the `hecks` runtime still writes the `miette`
/// chain, not the host's. REALM ONLY : `new_with_context` re-appends the
/// `context`, so passing `realm/context` here would double-nest it.
///
/// Falls back to the global `data_dir` unchanged when : the aggregate is
/// pathless (`realm_path` None — string-parsed, foreign roots) ; or the global
/// store is NOT under `data_root()` (an explicit / test dir like `/tmp/.heki`),
/// where realm-anchoring would wrongly escape the isolated store. So this is the
/// multi-root PRODUCTION fix, never a test redirect.
pub fn realm_store_dir(realm_path: Option<&str>, global: Option<&str>) -> Option<String> {
    let global = global?;
    let Some(rp) = realm_path else {
        return Some(global.to_string());
    };
    let root = data_root();
    if !std::path::Path::new(global).starts_with(&root) {
        return Some(global.to_string());
    }
    let realm = rp.split('/').next().unwrap_or(rp);
    Some(root.join(realm).to_string_lossy().into_owned())
}

/// Folder-derivation resolution (presence-switch on `dir :default`). When a
/// nearby `.world` declares `heki do; dir :default end`, the store mirrors the
/// bluebook location : rooted at the OS data root (data_root()), the project-relative folder chain
/// with `aggregates`/`bluebook` containers stripped and the trailing domain
/// folder dropped (the aggregate `context` re-adds it). `None` unless a nearby
/// world opts in.
#[cfg(target_arch = "wasm32")]
pub fn resolve_default_dir(_aggregates_path: &str) -> Option<String> { None }

#[cfg(not(target_arch = "wasm32"))]
pub fn resolve_default_dir(aggregates_path: &str) -> Option<String> {
    use std::path::{Path, PathBuf};
    let agg = Path::new(aggregates_path);
    let base = if agg.is_dir() { agg } else { agg.parent()? };
    let mut opts_in = false;
    for dir in [Some(base), base.parent()].into_iter().flatten() {
        let Ok(entries) = std::fs::read_dir(dir) else { continue };
        let mut worlds: Vec<PathBuf> = entries
            .filter_map(|e| e.ok())
            .map(|e| e.path())
            .filter(|p| p.extension().is_some_and(|x| x == "world"))
            .collect();
        worlds.sort();
        for wf in worlds {
            let Ok(src) = std::fs::read_to_string(&wf) else { continue };
            let world = crate::world::parser::parse(&src);
            if world.config_for("heki").and_then(|c| c.get("dir")) == Some("default") {
                opts_in = true;
                break;
            }
        }
        if opts_in { break; }
    }
    if !opts_in { return None; }
    // KEYED BY THE CONCEPTION DIRECTORY — a different directory is a different
    // store, which IS the isolation mechanism : a test runs from a tmpdir
    // conception and gets its OWN store, with no env redirect (HECKS_INFO is
    // gone). Under ~/Projects the key is the source-tree chain rooted at the
    // canonical live OS data root ; ANYWHERE ELSE (a /tmp test conception) the
    // store is co-located at <dir>/.heki — isolated, cleaned up with the
    // tmpdir, and never touching the live OS data root.
    let root = match default_chain(aggregates_path) {
        Some(chain) => data_root().join(chain),
        None => {
            let a = Path::new(aggregates_path);
            let base = if a.is_dir() { a } else { a.parent()? };
            base.join(".heki")
        }
    };
    std::fs::create_dir_all(&root).ok()?;
    Some(root.to_string_lossy().into_owned())
}

/// Project-relative chain for `:default` stores : path under ~/Projects,
/// `.bluebook` filename dropped, containers stripped, trailing domain folder
/// dropped. `None` when the target is not under ~/Projects.
pub fn default_chain(aggregates_path: &str) -> Option<String> {
    use std::path::{Component, Path};
    let abs = std::fs::canonicalize(aggregates_path)
        .unwrap_or_else(|_| Path::new(aggregates_path).to_path_buf());
    let projects_raw = expand_tilde("~/Projects");
    let projects = std::fs::canonicalize(&projects_raw)
        .unwrap_or_else(|_| Path::new(&projects_raw).to_path_buf());
    let rel = abs.strip_prefix(&projects).ok()?;
    let segs: Vec<String> = rel.components()
        .filter_map(|c| match c {
            Component::Normal(s) => s.to_str().map(|x| x.to_string()),
            _ => None,
        })
        .collect();
    strip_chain_segments(segs)
}

/// Pure segment transform for `:default` chains : drop a trailing `*.bluebook`
/// filename, strip `aggregates`/`bluebook` containers, drop the trailing domain
/// folder (re-added by `context`). `None` when nothing meaningful remains.
pub fn strip_chain_segments(mut segs: Vec<String>) -> Option<String> {
    if segs.last().is_some_and(|s| s.ends_with(".bluebook")) {
        segs.pop();
    }
    segs.retain(|s| s != "aggregates" && s != "bluebook");
    segs.pop(); // trailing domain folder — re-added by the aggregate context
    if segs.is_empty() { return None; }
    Some(segs.join("/"))
}

/// The (Realm, Context) of a bluebook — the first two address segments of
/// `Realm::Context::Bluebook::Aggregate.command`. REALM is the top project
/// folder under ~/Projects (`hecks`, `miette`). CONTEXT is the FOLDER chain
/// down to the bluebook's own directory (NOT the `category` keyword — the
/// physical folder, since category is semantic and will eventually be plural).
/// Container dirs (`hecks_conception` / `aggregates` / `bluebook`) are stripped
/// and the `.bluebook` filename dropped. Context is None when the bluebook sits
/// directly under the realm (then the address is `Realm::Bluebook::Aggregate`).
/// None realm when the path is not under ~/Projects (a foreign / isolated root).
pub fn folder_address(file_path: &str) -> (Option<String>, Option<String>) {
use std::path::{Component, Path};
let abs = std::fs::canonicalize(file_path)
    .unwrap_or_else(|_| Path::new(file_path).to_path_buf());
let projects_raw = expand_tilde("~/Projects");
let projects = std::fs::canonicalize(&projects_raw)
    .unwrap_or_else(|_| Path::new(&projects_raw).to_path_buf());
let Ok(rel) = abs.strip_prefix(&projects) else { return (None, None); };
let segs: Vec<String> = rel.components()
    .filter_map(|c| match c {
        Component::Normal(s) => s.to_str().map(|x| x.to_string()),
        _ => None,
    })
    .collect();
folder_address_segments(segs)
}

/// Pure segment transform for `folder_address` — drop a trailing `*.bluebook`
/// filename, strip the `hecks_conception` / `aggregates` / `bluebook` container
/// dirs, then split : first remaining segment = Realm, the rest = Context
/// (joined by `/`). `(None, None)` when nothing meaningful remains.
pub fn folder_address_segments(mut segs: Vec<String>) -> (Option<String>, Option<String>) {
    // Drop the *.bluebook filename ; then, if the bluebook sits in its OWN
    // same-named folder (agent_inbox/agent_inbox.bluebook), drop that folder too
    // — it is the bluebook's container, not a distinct Context level. Collapses
    // the folder==bluebook stutter (Realm::…::AgentInbox::AgentInbox →
    // Realm::…::AgentInbox) ; the same rule default_chain uses for storage.
    if let Some(file) = segs.last().cloned() {
        if file.ends_with(".bluebook") {
            segs.pop();
            let stem = file.trim_end_matches(".bluebook");
            if segs.last().map(|s| s.as_str()) == Some(stem) {
                segs.pop();
            }
        }
    }
    // A git worktree lives at `<repo>/.claude/worktrees/<name>/…` — those
    // three injected segments must NOT leak into the Realm/Context, or a
    // worktree's aggregates stamp a different realm_path than the main
    // checkout and realm-qualified dispatch (Realm::Context::Bluebook::
    // Aggregate.Cmd) silently fails to resolve from within a worktree. Drop
    // `.claude`, `worktrees`, and the worktree-name segment so a worktree
    // path normalizes to its main-checkout equivalent.
    if let Some(i) = segs.iter().position(|s| s == ".claude") {
        if segs.get(i + 1).map(|s| s.as_str()) == Some("worktrees") {
            let end = (i + 3).min(segs.len());
            segs.drain(i..end);
        }
    }
    segs.retain(|s| s != "hecks_conception" && s != "aggregates" && s != "bluebook");
    if segs.is_empty() { return (None, None); }
    let realm = segs.remove(0);
    let context = if segs.is_empty() { None } else { Some(segs.join("/")) };
    (Some(realm), context)
}

/// The INVERSE of folder_address : extract the Realm + Context of a
/// realm-qualified dispatch address `Realm[::Context…]::Bluebook::Aggregate.verb`.
/// Realm = the first `::` segment (when ≥ 3) ; Context = the middle segments
/// between the realm and the bluebook (the second-to-last), joined by `/`
/// (when ≥ 4). `(None, None)` for the legacy 2-segment `Bluebook::Aggregate`
/// form — nothing to enforce. Each segment is snake_cased so the PascalCase
/// address matches the snake_case folder path stamped on the aggregate. Shared
/// by the command resolver (command_dispatch) and the query path (main.rs).
pub fn fqn_realm_context(command_name: &str) -> (Option<String>, Option<String>) {
    let head = match command_name.rsplit_once('.') {
        Some((h, _)) => h,
        None => command_name,
    };
    let segs: Vec<&str> = head.split("::").collect();
    let n = segs.len();
    if n < 3 {
        return (None, None);
    }
    let realm = Some(crate::parser_helpers::to_snake_case(segs[0]));
    let context = if n >= 4 {
        Some(segs[1..n - 2].iter().map(|s| crate::parser_helpers::to_snake_case(s)).collect::<Vec<_>>().join("/"))
    } else {
        None
    };
    (realm, context)
}

/// Enforce a dispatch address's Realm + Context against the aggregate's stamped
/// folder address (`realm_path` = "realm/context"). LENIENT by design : it only
/// bites when BOTH sides carry the data — a legacy address with no realm, or an
/// aggregate with no stamped path (string-parsed / outside ~/Projects), passes
/// untouched. When the address gives a realm it must match ; when it also gives
/// a context that must match too. A realm-only (3-segment) address matches any
/// context under that realm — the transitional under-specified form ; the
/// canonical address carries the full context.
pub fn realm_context_matches(
    realm_path: Option<&str>,
    fqn_realm: Option<&str>,
    fqn_context: Option<&str>,
) -> bool {
    let Some(fqn_realm) = fqn_realm else { return true; };
    let Some(rp) = realm_path else { return true; };
    let (agg_realm, agg_context) = match rp.split_once('/') {
        Some((r, c)) => (r, Some(c)),
        None => (rp, None),
    };
    if fqn_realm != agg_realm { return false; }
    if let Some(fqn_ctx) = fqn_context {
        return agg_context == Some(fqn_ctx);
    }
    true
}

/// The ONE world-store resolver : realm override first, then `:default`
/// folder-derivation. `None` when no nearby world opts into either — caller
/// falls back to its legacy path. Shared by the writer (find_world_heki_dir)
/// and the reader (resolve_info_dir) so they never disagree.
pub fn resolve_world_store_dir(aggregates_path: &str) -> Option<String> {
    resolve_realm_dir(aggregates_path).or_else(|| resolve_default_dir(aggregates_path))
}

/// Canonical info_dir resolver — single source of truth for every
/// storehouse entry point (boot, statusline, loop, clock, manual CLI).
/// All three of `run_boot::resolve_info_dir`, `run_statusline::resolve_info_dir`,
/// and `main::find_world_heki_dir` delegate to this. Each daemon resolves
/// its OWN store from the world the same way boot does — no env is exported
/// (HECKS_INFO is gone : env-var routing was the one thing that could split
/// the writer from the reader).
///
/// Resolution order :
///
///   1. The `.world` store dir (realm / :default), probed from the repo root.
///   2. `<repo>/../miette-state/information` sibling (post-i142
///      private-state-as-peer-repo layout). Canonicalized when present.
///   3. `<repo>/hecks_conception/information` (in-tree fallback for
///      development without a private state repo).
///   4. `PathBuf::from("hecks_conception/information")` literal —
///      last-resort default for environments without a discoverable
///      repo root.
///
/// i154 — closes the class of bugs (i149, i153) where boot wrote to
/// one info_dir while statusline read another, or where loop daemons
/// resolved through `miette.world`'s relative `heki.dir` to a
/// non-existent path. miette.world's `heki.dir` is now documentation
/// only ; the runtime path no longer reads it.
pub fn resolve_info_dir() -> std::path::PathBuf {
    // The store location comes from the .world (`dir :default` / realm), NEVER an
    // env var. HECKS_INFO is GONE — env-var routing was the single source of
    // reader/writer store splits (i154/i728). Readers resolve the conception's
    // store the SAME way the dispatch writer does : probe the world under the repo
    // root. A bare bluebook with NO world persists to MEMORY, not a disk fallback
    // (run::infer_data_dir returns None), so a non-persisting run never reaches
    // here — which is why there is no live-store write left to redirect.
    // repo_root() (config-driven via HECKS_CONCEPTION_DIR, falling back to the
    // exe-walk) only LOCATES the conception ; the store location itself still
    // comes from the .world under it, never an env var (i154 — HECKS_INFO stays
    // gone). Env-located conception, world-derived store.
    if let Some(repo) = repo_root() {
        let agg = repo.join("hecks_conception/aggregates");
        if let Some(d) = resolve_world_store_dir(&agg.to_string_lossy()) {
            return std::path::PathBuf::from(d);
        }
    }
    if let Some(repo) = repo_root() {
        let sibling = repo.join("../miette-state/information");
        if sibling.is_dir() {
            return std::fs::canonicalize(&sibling).unwrap_or(sibling);
        }
        let fallback = repo.join("hecks_conception/information");
        if fallback.is_dir() {
            return fallback;
        }
    }
    // repo_root() is None : HECKS_CONCEPTION_DIR is unset AND no conception
    // was discoverable by walking up from the binary. Post-extraction (the
    // engine binary lives OUTSIDE the hecks tree) this is a real
    // misconfiguration, not a dev convenience. NEVER return the bare
    // relative `hecks_conception/information` : resolved against a cwd of
    // `.../hecks_conception` it silently DOUBLES into
    // `.../hecks_conception/hecks_conception/information`, splitting the
    // store — the i149/i153 reader/writer split i154 killed, reintroduced by
    // the move. Surface it loudly and return a double-PROOF cwd-anchored
    // path so a blind process can never split the store.
    eprintln!(
        "[storehouse] WARNING: cannot resolve the conception root \
         (HECKS_CONCEPTION_DIR unset, no discoverable hecks_conception/aggregates) \
         — set HECKS_CONCEPTION_DIR to the absolute hecks_conception directory. \
         Falling back to a cwd-anchored information/ store."
    );
    let cwd = std::env::current_dir().unwrap_or_else(|_| std::path::PathBuf::from("."));
    cwd_anchored_info_dir(&cwd)
}

/// Anchor an `information/` store on `cwd` WITHOUT doubling : when `cwd`
/// already ends in `hecks_conception`, return `<cwd>/information` rather
/// than `<cwd>/hecks_conception/information`. The last-resort store path
/// when the conception root can't be resolved — kept double-proof so a
/// blind process run from `.../hecks_conception` cannot split the store.
fn cwd_anchored_info_dir(cwd: &std::path::Path) -> std::path::PathBuf {
    if cwd.file_name().and_then(|n| n.to_str()) == Some("hecks_conception") {
        cwd.join("information")
    } else {
        cwd.join("hecks_conception/information")
    }
}

#[cfg(test)]
mod resolve_tests {
    use std::fs;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn tempdir() -> std::path::PathBuf {
        let nanos = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let p = std::env::temp_dir().join(format!("heki_resolve_test_{}", nanos));
        fs::create_dir_all(&p).unwrap();
        p
    }

    #[test]
    fn cwd_anchor_doubles_when_cwd_is_not_conception() {
        // A cwd that is NOT `.../hecks_conception` gets the conception
        // segment appended : `<cwd>/hecks_conception/information`.
        let cwd = std::path::Path::new("/Users/me/Projects/hecks");
        assert_eq!(
            super::cwd_anchored_info_dir(cwd),
            std::path::PathBuf::from("/Users/me/Projects/hecks/hecks_conception/information")
        );
    }

    #[test]
    fn cwd_anchor_is_double_proof_when_cwd_is_conception() {
        // The footgun this kills : cwd already ENDS in hecks_conception, so
        // appending another segment would write the doubled
        // `.../hecks_conception/hecks_conception/information`. The helper
        // anchors `information/` directly instead.
        let cwd = std::path::Path::new("/Users/me/Projects/hecks/hecks_conception");
        assert_eq!(
            super::cwd_anchored_info_dir(cwd),
            std::path::PathBuf::from("/Users/me/Projects/hecks/hecks_conception/information")
        );
        let _ = tempdir(); // sanity — temp helper still works
    }
}

/// Find the latest record in a store by updated_at field.
pub fn latest(store: &Store) -> Option<&Record> {
    store.values().max_by(|a, b| {
        let a_time = a.get("updated_at").and_then(|v| v.as_str()).unwrap_or("");
        let b_time = b.get("updated_at").and_then(|v| v.as_str()).unwrap_or("");
        a_time.cmp(b_time)
    })
}

/// Get a string field from a record, or a default.
pub fn field_str<'a>(record: &'a Record, key: &str) -> &'a str {
    record.get(key).and_then(|v| v.as_str()).unwrap_or("—")
}

/// Get a float field from a record.
pub fn field_f64(record: &Record, key: &str) -> Option<f64> {
    record.get(key).and_then(|v| v.as_f64())
}

/// Parse "key=value key2=value2" into a Record.
pub fn parse_attrs(pairs: &[String]) -> Record {
    let mut attrs = Record::new();
    for pair in pairs {
        if let Some(eq) = pair.find('=') {
            let key = pair[..eq].to_string();
            let val_str = &pair[eq+1..];
            let val = if let Ok(n) = val_str.parse::<i64>() {
                serde_json::Value::Number(n.into())
            } else if let Ok(f) = val_str.parse::<f64>() {
                serde_json::json!(f)
            } else if val_str == "true" {
                serde_json::Value::Bool(true)
            } else if val_str == "false" {
                serde_json::Value::Bool(false)
            } else {
                serde_json::Value::String(val_str.to_string())
            };
            attrs.insert(key, val);
        }
    }
    attrs
}




// ---------------------------------------------------------------------------
// Summary
// ---------------------------------------------------------------------------

/// Print a hydrate summary — vital signs from .heki stores.
pub fn print_summary(stores: &HashMap<String, Store>) {
    let total: usize = stores.values().map(|s| s.len()).sum();

    let mood = stores.get("mood").and_then(|s| latest(s));
    let pulse = stores.get("heartbeat").and_then(|s| latest(s));
    let census = stores.get("census").and_then(|s| latest(s));
    let heartbeat = stores.get("heartbeat").and_then(|s| latest(s));
    let conversation = stores.get("conversation").and_then(|s| latest(s));
    let identity = stores.get("identity").and_then(|s| latest(s));

    let domains = census.map_or("?".to_string(), |r| {
        r.get("total_domains").map_or("?".to_string(), |v| v.to_string())
    });
    let aggs = census.map_or("?".to_string(), |r| {
        r.get("total_aggregates").map_or("?".to_string(), |v| v.to_string())
    });
    let sectors = census.map_or("?".to_string(), |r| {
        r.get("sector_count").map_or("?".to_string(), |v| v.to_string())
    });

    println!("  \x1b[96m❄\x1b[0m  {} records, {} domains, {} aggregates, {} sectors",
        total, domains, aggs, sectors);

    let mood_state = mood.map_or("—", |r| field_str(r, "current_state"));
    let flow = pulse.map_or("—", |r| field_str(r, "flow_rate"));
    let beats = heartbeat.map_or("?".to_string(), |r| {
        r.get("beats").map_or("?".to_string(), |v| v.to_string())
    });
    let person = conversation.map_or("—", |r| field_str(r, "person_name"));
    let sessions = identity.map_or("?".to_string(), |r| {
        r.get("sessions").map_or("?".to_string(), |v| v.to_string())
    });

    // Self checkin — vitals
    let fatigue = pulse.and_then(|r| r.get("fatigue").and_then(|v| v.as_f64())).unwrap_or(0.0);
    let fatigue_state = pulse.map_or("—", |r| field_str(r, "fatigue_state"));
    let carrying = pulse.map_or("—", |r| field_str(r, "carrying"));
    let pss = pulse.and_then(|r| r.get("pulses_since_sleep").and_then(|v| v.as_i64())).unwrap_or(0);

    // Self checkin — inner weather
    let creativity = mood.and_then(|r| r.get("creativity_level").and_then(|v| v.as_f64())).unwrap_or(0.0);
    let precision = mood.and_then(|r| r.get("precision_level").and_then(|v| v.as_f64())).unwrap_or(0.0);

    // Self checkin — wakefulness
    let consciousness = stores.get("consciousness").and_then(|s| latest(s));
    let conscious_state = consciousness.map_or("—", |r| field_str(r, "state"));

    // Self checkin — presence
    let awareness = stores.get("awareness").and_then(|s| latest(s));
    let age_days = awareness.and_then(|r| r.get("age_days").and_then(|v| v.as_f64())).unwrap_or(0.0);

    if mood_state != "—" || flow != "—" {
        println!("  mood: {}  pulse: {}  beats: {}  person: {}  sessions: {}",
            mood_state, flow, beats, person, sessions);
    }
    println!("  fatigue: {} ({})  carrying: \"{}\"  pulses since sleep: {}",
        fatigue, fatigue_state, carrying, pss);
    println!("  creativity: {:.1}  precision: {:.1}  consciousness: {}  age: {:.1} days",
        creativity, precision, conscious_state, age_days);

    println!("  {} stores, {} total records", stores.len(), total);
}

#[cfg(test)]
mod world_resolution_tests {
//! World-aware store resolution — realm override + :default folder chain.
//! Hermetic : no env mutation, absolute dirs only, so these never race on
//! `$HOME` or a shared temp dir.
use super::{data_root, expand_tilde, folder_address_segments, fqn_realm_context, realm_store_dir, resolve_realm_dir, strip_chain_segments};
use std::fs;
use std::time::{SystemTime, UNIX_EPOCH};

fn segs(parts: &[&str]) -> Vec<String> {
    parts.iter().map(|s| s.to_string()).collect()
}

#[test]
fn default_chain_pizzas_strips_bluebook_and_trailing_domain() {
    assert_eq!(
        strip_chain_segments(segs(&["hecks", "examples", "pizzas", "bluebook"])),
        Some("hecks/examples".to_string())
    );
}

#[test]
fn default_chain_strips_aggregates_and_drops_bluebook_filename() {
    assert_eq!(
        strip_chain_segments(segs(&["hecks", "hecks_conception", "aggregates", "framework", "tools", "git.bluebook"])),
        Some("hecks/hecks_conception/framework".to_string())
    );
}

#[test]
fn default_chain_too_shallow_is_none() {
    assert_eq!(strip_chain_segments(segs(&["hecks"])), None);
    assert_eq!(strip_chain_segments(segs(&["aggregates", "bluebook"])), None);
}

// ---- folder_address : (Realm, Context) of the FQN ----

#[test]
fn folder_address_realm_plus_context() {
    // …/hecks/hecks_conception/aggregates/language/grammar/sentence.bluebook
    // → realm "hecks", context "language/grammar" (containers stripped, file dropped).
    assert_eq!(
        folder_address_segments(segs(&["hecks", "hecks_conception", "aggregates", "language", "grammar", "sentence.bluebook"])),
        (Some("hecks".to_string()), Some("language/grammar".to_string()))
    );
}

#[test]
fn folder_address_strips_worktree_path_segments() {
    // A git worktree path …/hecks/.claude/worktrees/<name>/hecks_conception/…
    // must normalize to the SAME (realm, context) as the main checkout, or
    // realm-qualified dispatch fails from inside a worktree (the .claude/
    // worktrees/<name> segments would otherwise leak into Context).
    assert_eq!(
        folder_address_segments(segs(&["hecks", ".claude", "worktrees", "governance-barrier-rehome", "hecks_conception", "aggregates", "world", "conception", "corpus.bluebook"])),
        (Some("hecks".to_string()), Some("world/conception".to_string()))
    );
}

#[test]
fn folder_address_drops_the_bluebooks_own_folder() {
    // fibroblast/fibroblast.bluebook — the bluebook's own same-named folder is
    // dropped (collapses the folder==bluebook stutter) ; the rest is Context.
    assert_eq!(
        folder_address_segments(segs(&["hecks", "hecks_conception", "aggregates", "discipline", "immune_system", "repair_cell", "fibroblast", "fibroblast.bluebook"])),
        (Some("hecks".to_string()), Some("discipline/immune_system/repair_cell".to_string()))
    );
}

#[test]
fn folder_address_keeps_folder_when_not_named_after_bluebook() {
    // grammar/sentence.bluebook — folder "grammar" ≠ "sentence", so it stays.
    assert_eq!(
        folder_address_segments(segs(&["hecks", "hecks_conception", "aggregates", "language", "grammar", "sentence.bluebook"])),
        (Some("hecks".to_string()), Some("language/grammar".to_string()))
    );
}

#[test]
fn folder_address_miette_is_its_own_realm() {
    // Miette's body is a sibling realm — the multi-root corpus the resolver disambiguates.
    assert_eq!(
        folder_address_segments(segs(&["miette", "body", "cycles", "heartbeat.bluebook"])),
        (Some("miette".to_string()), Some("body/cycles".to_string()))
    );
}

#[test]
fn folder_address_no_context_directly_under_realm() {
    // Bluebook directly under the realm → Realm::Bluebook::Aggregate (context None).
    assert_eq!(
        folder_address_segments(segs(&["hecks", "hecks_conception", "aggregates", "pizzas.bluebook"])),
        (Some("hecks".to_string()), None)
    );
}

#[test]
fn folder_address_empty_is_none() {
    assert_eq!(folder_address_segments(segs(&["aggregates", "bluebook"])), (None, None));
    assert_eq!(folder_address_segments(segs(&[])), (None, None));
}

// ---- fqn_realm_context : the address → (Realm, Context), inverse of folder_address ----

#[test]
fn fqn_realm_context_extracts_and_snake_cases() {
    // 2-seg legacy — nothing to enforce.
    assert_eq!(fqn_realm_context("AgentInbox::AgentMessage.AllUnread"), (None, None));
    // 3-seg — realm only.
    assert_eq!(fqn_realm_context("Hecks::AgentInbox::AgentMessage.all_unread"),
        (Some("hecks".to_string()), None));
    // 4-seg — realm + one context folder.
    assert_eq!(fqn_realm_context("Hecks::Framework::AgentInbox::AgentMessage.all_unread"),
        (Some("hecks".to_string()), Some("framework".to_string())));
    // 5-seg — realm + nested context.
    assert_eq!(fqn_realm_context("Miette::Body::Organs::Heart::Heart.Beat"),
        (Some("miette".to_string()), Some("body/organs".to_string())));
    // PascalCase address segment ↔ snake_case folder.
    assert_eq!(fqn_realm_context("Hecks::ImmuneSystem::Macrophage::Macrophage.Run"),
        (Some("hecks".to_string()), Some("immune_system".to_string())));
}

fn tempdir(tag: &str) -> std::path::PathBuf {
    let nanos = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    let p = std::env::temp_dir().join(format!("world_res_test_{}_{}", tag, nanos));
    fs::create_dir_all(&p).unwrap();
    p
}

#[test]
fn expand_tilde_expands_home_prefix() {
    let home = std::env::var("HOME").expect("HOME set in test env");
    assert_eq!(expand_tilde("~/data"), format!("{}/data", home.trim_end_matches('/')));
    assert_eq!(expand_tilde("~"), home);
}

#[test]
fn expand_tilde_passes_through_absolute_and_relative() {
    assert_eq!(expand_tilde("/abs/path"), "/abs/path");
    assert_eq!(expand_tilde("rel/path"), "rel/path");
}

#[test]
fn realm_world_nests_snake_realm_and_creates_dir() {
    let dir = tempdir("present");
    let store = dir.join("store");
    let world = format!(
        "Hecks.world \"Demo\" do\n  realm \"MyRealm\"\n  heki do\n    dir \"{}\"\n  end\nend\n",
        store.to_string_lossy()
    );
    fs::write(dir.join("demo.world"), world).unwrap();

    let resolved = resolve_realm_dir(dir.to_str().unwrap())
        .expect("realm-bearing world resolves");
    let expected = store.join("my_realm");
    assert_eq!(resolved, expected.to_string_lossy());
    assert!(expected.is_dir(), "realm dir is created on resolution");
}

#[test]
fn realm_less_world_declines_so_legacy_path_is_untouched() {
    let root = tempdir("absent");
    let agg = root.join("agg");
    fs::create_dir_all(&agg).unwrap();
    let world = "Hecks.world \"Demo\" do\n  heki do\n    dir \"/tmp/legacy-store\"\n  end\nend\n";
    fs::write(agg.join("demo.world"), world).unwrap();
    assert!(resolve_realm_dir(agg.to_str().unwrap()).is_none());
}

#[test]
fn realm_store_dir_anchors_on_aggregate_realm_under_data_root() {
    let root = data_root();
    // A miette aggregate loaded while the host runtime's global store is the
    // hecks chain still resolves to the miette chain — the multi-root fix.
    let global = root.join("hecks");
    assert_eq!(
        realm_store_dir(Some("miette/transparency"), global.to_str()),
        Some(root.join("miette").to_string_lossy().into_owned())
    );
    // A hecks aggregate on the hecks global is unchanged (realm == host).
    assert_eq!(
        realm_store_dir(Some("hecks"), global.to_str()),
        Some(root.join("hecks").to_string_lossy().into_owned())
    );
}

#[test]
fn realm_store_dir_preserves_explicit_test_dir() {
    // A /tmp store (NOT under data_root) is an isolated / test dir — realm
    // anchoring must NOT escape it, even for a realm-bearing aggregate.
    assert_eq!(
        realm_store_dir(Some("miette/body"), Some("/tmp/iso/.heki")),
        Some("/tmp/iso/.heki".to_string())
    );
    // Pathless aggregate (no realm) — global unchanged.
    assert_eq!(
        realm_store_dir(None, Some("/tmp/iso/.heki")),
        Some("/tmp/iso/.heki".to_string())
    );
    // No global — None.
    assert_eq!(realm_store_dir(Some("miette"), None), None);
}
}
