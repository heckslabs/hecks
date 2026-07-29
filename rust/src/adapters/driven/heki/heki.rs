use flate2::Compression;
use std::collections::HashMap;
use std::fs;
use std::io::Read as IoRead;
use std::io::Write as IoWrite;
use std::path::Path;

pub type Record = HashMap<String, serde_json::Value>;

pub type Store = HashMap<String, Record>;

#[derive(Debug, Clone, Copy)]
pub enum WriteContext<'a> {
    Dispatch {
        aggregate: &'a str,
        command: &'a str,
    },

    OutOfBand {
        reason: &'a str,
    },
}

impl<'a> WriteContext<'a> {
    fn audit_tag(&self) -> String {
        match self {
            WriteContext::Dispatch { aggregate, command } => {
                format!("dispatch:{}.{}", aggregate, command)
            }
            WriteContext::OutOfBand { reason } => format!("out-of-band:{}", reason),
        }
    }
}

fn audit_write(ctx: &WriteContext, path: &str, op: &str) {
    let always = matches!(ctx, WriteContext::OutOfBand { .. });
    let verbose = std::env::var("HECKS_HEKI_AUDIT").ok().as_deref() == Some("1");
    if always || verbose {
        eprintln!("[heki:{}] {} → {}", op, ctx.audit_tag(), path);
    }
}

pub fn snapshot(path: &str) -> Result<Option<String>, String> {
    let src = Path::new(path);
    if !src.exists() {
        return Ok(None);
    }

    let parent = src
        .parent()
        .ok_or_else(|| format!("snapshot: cannot determine parent dir of {}", path))?;
    let basename = src
        .file_stem()
        .and_then(|s| s.to_str())
        .ok_or_else(|| format!("snapshot: cannot determine basename of {}", path))?;

    let snap_dir = parent.join(".heki-snapshots");
    fs::create_dir_all(&snap_dir)
        .map_err(|e| format!("snapshot: cannot create {}: {}", snap_dir.display(), e))?;

    let ts = crate::clock::now_iso8601_internal();
    let mut snap_path = snap_dir.join(format!("{}.{}.heki", basename, ts));
    let mut n = 1;
    while snap_path.exists() {
        snap_path = snap_dir.join(format!("{}.{}.{}.heki", basename, ts, n));
        n += 1;
    }

    fs::copy(src, &snap_path)
        .map_err(|e| format!("snapshot: copy {} → {}: {}", path, snap_path.display(), e))?;

    Ok(Some(snap_path.to_string_lossy().into_owned()))
}

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
    decoder
        .read_to_string(&mut json_str)
        .map_err(|e| format!("{}: zlib error: {}", path, e))?;

    let store: Store =
        serde_json::from_str(&json_str).map_err(|e| format!("{}: json error: {}", path, e))?;

    Ok(store)
}

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
        let name = file_path
            .file_stem()
            .and_then(|s| s.to_str())
            .unwrap_or("unknown")
            .to_string();
        match read(file_path.to_str().unwrap_or("")) {
            Ok(store) => {
                all.insert(name, store);
            }
            Err(e) => eprintln!("  skip: {}", e),
        }
    }

    Ok(all)
}

const REDACTED_FIELDS: &[(&str, &[&str])] = &[("creator_auth", &["passcode"])];

fn sanitize(path: &str, store: &Store) -> Store {
    let name = Path::new(path)
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("");
    let fields: Vec<&str> = REDACTED_FIELDS
        .iter()
        .filter(|(n, _)| *n == name)
        .flat_map(|(_, fs)| fs.iter().copied())
        .collect();
    if fields.is_empty() {
        return store.clone();
    }
    let mut clean = store.clone();
    for rec in clean.values_mut() {
        for f in &fields {
            rec.remove(*f);
        }
    }
    clean
}

pub fn write(path: &str, store: &Store, ctx: WriteContext<'_>) -> Result<(), String> {
    audit_write(&ctx, path, "persist");
    write_raw(path, store)
}

fn write_raw(path: &str, store: &Store) -> Result<(), String> {
    let store = sanitize(path, store);
    let json = serde_json::to_string(&store).map_err(|e| format!("json serialize: {}", e))?;

    let mut encoder = flate2::write::ZlibEncoder::new(Vec::new(), Compression::best());
    encoder
        .write_all(json.as_bytes())
        .map_err(|e| format!("zlib compress: {}", e))?;
    let compressed = encoder
        .finish()
        .map_err(|e| format!("zlib finish: {}", e))?;

    let count = store.len() as u32;
    let mut out = Vec::with_capacity(8 + compressed.len());
    out.extend_from_slice(b"HEKI");
    out.extend_from_slice(&count.to_be_bytes());
    out.extend_from_slice(&compressed);

    fs::write(path, &out).map_err(|e| format!("write {}: {}", path, e))
}

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

pub fn upsert(path: &str, attrs: &Record, ctx: WriteContext<'_>) -> Result<Record, String> {
    audit_write(&ctx, path, "upsert");
    let mut store = read(path)?;
    let now = crate::clock::now_iso8601_internal();

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

pub fn delete(path: &str, id: &str, ctx: WriteContext<'_>) -> Result<bool, String> {
    audit_write(&ctx, path, "delete");
    let mut store = read(path)?;
    let removed = store.remove(id).is_some();
    if removed {
        write_raw(path, &store)?;
    }
    Ok(removed)
}

pub fn archive(
    source_path: &str,
    archive_path: &str,
    id: &str,
    reason: &str,
    ctx: WriteContext<'_>,
) -> Result<bool, String> {
    audit_write(&ctx, source_path, "archive");
    let mut store = read(source_path)?;
    if let Some(mut rec) = store.remove(id) {
        rec.insert(
            "archived_reason".into(),
            serde_json::Value::String(reason.into()),
        );
        rec.insert(
            "archived_at".into(),
            serde_json::Value::String(crate::clock::now_iso8601_internal()),
        );
        write_raw(source_path, &store)?;
        let mut store = read(archive_path)?;
        let id_val = rec
            .get("id")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string())
            .unwrap_or_else(crate::util::uuid_v4);
        store.insert(id_val, rec);
        write_raw(archive_path, &store)?;
        Ok(true)
    } else {
        Ok(false)
    }
}

pub fn store_path(dir: &str, name: &str) -> String {
    Path::new(dir)
        .join(format!("{}.heki", name))
        .to_string_lossy()
        .into_owned()
}

pub fn path_for(dir: &str, aggregate: &str, context: Option<&str>) -> String {
    let agg_snake = crate::naming::snake(aggregate);
    match context {
        Some(ctx) if !ctx.is_empty() => {
            let ctx_snake = crate::naming::snake(ctx);
            format!("{}/{}/{}.heki", dir, ctx_snake, agg_snake)
        }
        _ => format!("{}/{}.heki", dir, agg_snake),
    }
}

pub fn path_for_lookup(dir: &str, name: &str) -> String {
    let happy = format!("{}/{}/{}.heki", dir, name, name);
    if Path::new(&happy).exists() {
        return happy;
    }
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
    format!("{}/{}.heki", dir, name)
}

#[cfg(test)]
mod path_tests {
    use super::*;
    use std::fs;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn tempdir() -> std::path::PathBuf {
        use std::sync::atomic::{AtomicU64, Ordering};
        static SEQ: AtomicU64 = AtomicU64::new(0);
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let seq = SEQ.fetch_add(1, Ordering::Relaxed);
        let p = std::env::temp_dir().join(format!("heki_path_test_{}_{}", nanos, seq));
        fs::create_dir_all(&p).unwrap();
        p
    }

    #[test]
    fn walk_up_from_requires_aggregates_not_a_bare_hecks_conception() {
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
        let base = tempdir();
        let repo = base.join("a_repo");
        let conception = repo.join("hecks_conception");
        fs::create_dir_all(conception.join("aggregates")).unwrap();
        assert_eq!(
            repo_root_from_conception_dir(Some(conception.to_string_lossy().into_owned())),
            Some(repo.clone())
        );
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
        assert_eq!(
            config_conception_path_from(Some("/cfg".into()), Some("/home/u".into())),
            Some(std::path::PathBuf::from("/cfg/storehouse/conception"))
        );
        assert_eq!(
            config_conception_path_from(Some(String::new()), Some("/home/u".into())),
            Some(std::path::PathBuf::from(
                "/home/u/.config/storehouse/conception"
            ))
        );
        assert_eq!(config_conception_path_from(None, None), None);
    }

    #[test]
    fn read_conception_config_trims_and_rejects_blank() {
        let dir = tempdir();
        let file = dir.join("conception");
        fs::write(&file, "  /Users/x/Projects/hecks/hecks_conception\n").unwrap();
        assert_eq!(
            read_conception_config(&file),
            Some("/Users/x/Projects/hecks/hecks_conception".to_string())
        );
        fs::write(&file, "   \n").unwrap();
        assert_eq!(read_conception_config(&file), None);
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
        let dir = tempdir();
        let flat_file = dir.join("mood.heki");
        fs::write(&flat_file, "{}").unwrap();

        let chosen = path_for_lookup(&dir.to_string_lossy(), "mood");
        assert_eq!(chosen, format!("{}/mood.heki", dir.display()));

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn lookup_returns_flat_when_neither_exists() {
        let dir = tempdir();
        let chosen = path_for_lookup(&dir.to_string_lossy(), "nope");
        assert_eq!(chosen, format!("{}/nope.heki", dir.display()));
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn writer_and_reader_agree_on_nested_path() {
        let dir = tempdir();
        let writer_path = path_for(&dir.to_string_lossy(), "Mood", Some("Body"));
        if let Some(parent) = std::path::Path::new(&writer_path).parent() {
            fs::create_dir_all(parent).unwrap();
        }
        fs::write(&writer_path, "{}").unwrap();

        let reader_path = path_for_lookup(&dir.to_string_lossy(), "mood");
        assert_eq!(
            writer_path, reader_path,
            "writer (path_for) and reader (path_for_lookup) must agree"
        );
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn writer_and_reader_agree_on_flat_path() {
        let dir = tempdir();
        let writer_path = path_for(&dir.to_string_lossy(), "Mood", None);
        fs::write(&writer_path, "{}").unwrap();

        let reader_path = path_for_lookup(&dir.to_string_lossy(), "mood");
        assert_eq!(
            writer_path, reader_path,
            "writer (no context) and reader must both pick flat"
        );
        let _ = fs::remove_dir_all(&dir);
    }
}

pub fn repo_root() -> Option<std::path::PathBuf> {
    if let Some(root) = repo_root_from_conception_dir(std::env::var("HECKS_CONCEPTION_DIR").ok()) {
        return Some(root);
    }
    if let Some(root) = walk_up_for_repo_root() {
        return Some(root);
    }
    repo_root_from_conception_dir(config_conception_dir())
}

fn repo_root_from_conception_dir(env_val: Option<String>) -> Option<std::path::PathBuf> {
    let p = env_val.filter(|s| !s.is_empty())?;
    let conception = std::path::PathBuf::from(p);
    if conception.is_dir() {
        conception.parent().map(|x| x.to_path_buf())
    } else {
        None
    }
}

fn config_conception_dir() -> Option<String> {
    read_conception_config(&config_conception_path()?)
}

fn config_conception_path() -> Option<std::path::PathBuf> {
    config_conception_path_from(
        std::env::var("XDG_CONFIG_HOME").ok(),
        std::env::var("HOME").ok(),
    )
}

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

fn walk_up_from(start: &std::path::Path) -> Option<std::path::PathBuf> {
    let mut cur: std::path::PathBuf = start.to_path_buf();
    for _ in 0..10 {
        if cur.join("hecks_conception").join("aggregates").is_dir() {
            let s = cur.to_string_lossy();
            if !s.contains("/.claude/worktrees/") {
                return Some(cur);
            }
        }
        let parent = cur.parent()?.to_path_buf();
        if parent == cur {
            break;
        }
        cur = parent;
    }
    None
}

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

#[cfg(target_arch = "wasm32")]
pub fn resolve_realm_dir(_aggregates_path: &str) -> Option<String> {
    None
}

#[cfg(not(target_arch = "wasm32"))]
pub fn resolve_realm_dir(aggregates_path: &str) -> Option<String> {
    use std::path::{Path, PathBuf};
    let agg = Path::new(aggregates_path);
    let base = if agg.is_dir() { agg } else { agg.parent()? };
    for dir in [Some(base), base.parent()].into_iter().flatten() {
        let entries = match std::fs::read_dir(dir) {
            Ok(e) => e,
            Err(_) => continue,
        };
        let mut worlds: Vec<PathBuf> = entries
            .filter_map(|e| e.ok())
            .map(|e| e.path())
            .filter(|p| p.extension().is_some_and(|ext| ext == "world"))
            .collect();
        worlds.sort();
        for wf in worlds {
            let source = match std::fs::read_to_string(&wf) {
                Ok(s) => s,
                Err(_) => continue,
            };
            let world = crate::world::parser::parse(&source);
            let realm = match &world.realm {
                Some(r) if !r.is_empty() => r,
                _ => continue,
            };
            let dir_value = match world.config_for("heki").and_then(|c| c.get("dir")) {
                Some(d) => d,
                None => continue,
            };
            let root = Path::new(&expand_tilde(dir_value)).join(crate::naming::snake(realm));
            std::fs::create_dir_all(&root).ok()?;
            return Some(root.to_string_lossy().into_owned());
        }
    }
    None
}

pub fn data_root() -> std::path::PathBuf {
    use std::path::PathBuf;
    let base: PathBuf = if cfg!(target_os = "macos") {
        std::env::var("HOME")
            .ok()
            .map(|h| PathBuf::from(h).join("Library/Application Support"))
            .unwrap_or_else(|| PathBuf::from(expand_tilde("~/.local/share")))
    } else if cfg!(target_os = "windows") {
        std::env::var("APPDATA")
            .ok()
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from(expand_tilde("~/AppData/Roaming")))
    } else {
        std::env::var("XDG_DATA_HOME")
            .ok()
            .map(PathBuf::from)
            .or_else(|| {
                std::env::var("HOME")
                    .ok()
                    .map(|h| PathBuf::from(h).join(".local/share"))
            })
            .unwrap_or_else(|| PathBuf::from(expand_tilde("~/.local/share")))
    };
    base.join("Hecks")
}

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

#[cfg(target_arch = "wasm32")]
pub fn resolve_default_dir(_aggregates_path: &str) -> Option<String> {
    None
}

#[cfg(not(target_arch = "wasm32"))]
pub fn resolve_default_dir(aggregates_path: &str) -> Option<String> {
    use std::path::{Path, PathBuf};
    let agg = Path::new(aggregates_path);
    let base = if agg.is_dir() { agg } else { agg.parent()? };
    let mut opts_in = false;
    for dir in [Some(base), base.parent()].into_iter().flatten() {
        let Ok(entries) = std::fs::read_dir(dir) else {
            continue;
        };
        let mut worlds: Vec<PathBuf> = entries
            .filter_map(|e| e.ok())
            .map(|e| e.path())
            .filter(|p| p.extension().is_some_and(|x| x == "world"))
            .collect();
        worlds.sort();
        for wf in worlds {
            let Ok(src) = std::fs::read_to_string(&wf) else {
                continue;
            };
            let world = crate::world::parser::parse(&src);
            if world.config_for("heki").and_then(|c| c.get("dir")) == Some("default") {
                opts_in = true;
                break;
            }
        }
        if opts_in {
            break;
        }
    }
    if !opts_in {
        return None;
    }
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

pub fn default_chain(aggregates_path: &str) -> Option<String> {
    use std::path::{Component, Path};
    let abs = std::fs::canonicalize(aggregates_path)
        .unwrap_or_else(|_| Path::new(aggregates_path).to_path_buf());
    let projects_raw = expand_tilde("~/Projects");
    let projects = std::fs::canonicalize(&projects_raw)
        .unwrap_or_else(|_| Path::new(&projects_raw).to_path_buf());
    let rel = abs.strip_prefix(&projects).ok()?;
    let segs: Vec<String> = rel
        .components()
        .filter_map(|c| match c {
            Component::Normal(s) => s.to_str().map(|x| x.to_string()),
            _ => None,
        })
        .collect();
    strip_chain_segments(segs)
}

pub fn strip_chain_segments(mut segs: Vec<String>) -> Option<String> {
    if segs.last().is_some_and(|s| s.ends_with(".bluebook")) {
        segs.pop();
    }
    segs.retain(|s| s != "aggregates" && s != "bluebook");
    segs.pop();
    if segs.is_empty() {
        return None;
    }
    Some(segs.join("/"))
}

pub fn folder_address(file_path: &str) -> (Option<String>, Option<String>) {
    use std::path::{Component, Path};
    let abs =
        std::fs::canonicalize(file_path).unwrap_or_else(|_| Path::new(file_path).to_path_buf());
    let projects_raw = expand_tilde("~/Projects");
    let projects = std::fs::canonicalize(&projects_raw)
        .unwrap_or_else(|_| Path::new(&projects_raw).to_path_buf());
    let Ok(rel) = abs.strip_prefix(&projects) else {
        return (None, None);
    };
    let segs: Vec<String> = rel
        .components()
        .filter_map(|c| match c {
            Component::Normal(s) => s.to_str().map(|x| x.to_string()),
            _ => None,
        })
        .collect();
    folder_address_segments(segs)
}

pub fn folder_address_segments(mut segs: Vec<String>) -> (Option<String>, Option<String>) {
    if let Some(file) = segs.last().cloned() {
        if file.ends_with(".bluebook") {
            segs.pop();
            let stem = file.trim_end_matches(".bluebook");
            if segs.last().map(|s| s.as_str()) == Some(stem) {
                segs.pop();
            }
        }
    }
    if let Some(i) = segs.iter().position(|s| s == ".claude") {
        if segs.get(i + 1).map(|s| s.as_str()) == Some("worktrees") {
            let end = (i + 3).min(segs.len());
            segs.drain(i..end);
        }
    }
    segs.retain(|s| s != "hecks_conception" && s != "aggregates" && s != "bluebook");
    if segs.is_empty() {
        return (None, None);
    }
    let realm = segs.remove(0);
    let context = if segs.is_empty() {
        None
    } else {
        Some(segs.join("/"))
    };
    (Some(realm), context)
}

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
    let realm = Some(crate::naming::snake(segs[0]));
    let context = if n >= 4 {
        Some(
            segs[1..n - 2]
                .iter()
                .map(|s| crate::naming::snake(s))
                .collect::<Vec<_>>()
                .join("/"),
        )
    } else {
        None
    };
    (realm, context)
}

pub fn realm_context_matches(
    realm_path: Option<&str>,
    fqn_realm: Option<&str>,
    fqn_context: Option<&str>,
) -> bool {
    let Some(fqn_realm) = fqn_realm else {
        return true;
    };
    let Some(rp) = realm_path else {
        return true;
    };
    let (agg_realm, agg_context) = match rp.split_once('/') {
        Some((r, c)) => (r, Some(c)),
        None => (rp, None),
    };
    if fqn_realm != agg_realm {
        return false;
    }
    if let Some(fqn_ctx) = fqn_context {
        return agg_context == Some(fqn_ctx);
    }
    true
}

pub fn resolve_world_store_dir(aggregates_path: &str) -> Option<String> {
    resolve_realm_dir(aggregates_path).or_else(|| resolve_default_dir(aggregates_path))
}

pub fn resolve_info_dir() -> std::path::PathBuf {
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
    eprintln!(
        "[storehouse] WARNING: cannot resolve the conception root \
         (HECKS_CONCEPTION_DIR unset, no discoverable hecks_conception/aggregates) \
         — set HECKS_CONCEPTION_DIR to the absolute hecks_conception directory. \
         Falling back to a cwd-anchored information/ store."
    );
    let cwd = std::env::current_dir().unwrap_or_else(|_| std::path::PathBuf::from("."));
    cwd_anchored_info_dir(&cwd)
}

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
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let p = std::env::temp_dir().join(format!("heki_resolve_test_{}", nanos));
        fs::create_dir_all(&p).unwrap();
        p
    }

    #[test]
    fn cwd_anchor_doubles_when_cwd_is_not_conception() {
        let cwd = std::path::Path::new("/Users/me/Projects/hecks");
        assert_eq!(
            super::cwd_anchored_info_dir(cwd),
            std::path::PathBuf::from("/Users/me/Projects/hecks/hecks_conception/information")
        );
    }

    #[test]
    fn cwd_anchor_is_double_proof_when_cwd_is_conception() {
        let cwd = std::path::Path::new("/Users/me/Projects/hecks/hecks_conception");
        assert_eq!(
            super::cwd_anchored_info_dir(cwd),
            std::path::PathBuf::from("/Users/me/Projects/hecks/hecks_conception/information")
        );
        let _ = tempdir();
    }
}

pub fn latest(store: &Store) -> Option<&Record> {
    store.values().max_by(|a, b| {
        let a_time = a.get("updated_at").and_then(|v| v.as_str()).unwrap_or("");
        let b_time = b.get("updated_at").and_then(|v| v.as_str()).unwrap_or("");
        a_time.cmp(b_time)
    })
}

pub fn field_str<'a>(record: &'a Record, key: &str) -> &'a str {
    record.get(key).and_then(|v| v.as_str()).unwrap_or("—")
}

pub fn field_f64(record: &Record, key: &str) -> Option<f64> {
    record.get(key).and_then(|v| v.as_f64())
}

pub fn parse_attrs(pairs: &[String]) -> Record {
    let mut attrs = Record::new();
    for pair in pairs {
        if let Some(eq) = pair.find('=') {
            let key = pair[..eq].to_string();
            let val_str = &pair[eq + 1..];
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

pub fn print_summary(stores: &HashMap<String, Store>) {
    let total: usize = stores.values().map(|s| s.len()).sum();

    let mood = stores.get("mood").and_then(|s| latest(s));
    let pulse = stores.get("heartbeat").and_then(|s| latest(s));
    let census = stores.get("census").and_then(|s| latest(s));
    let heartbeat = stores.get("heartbeat").and_then(|s| latest(s));
    let conversation = stores.get("conversation").and_then(|s| latest(s));
    let identity = stores.get("identity").and_then(|s| latest(s));

    let domains = census.map_or("?".to_string(), |r| {
        r.get("total_domains")
            .map_or("?".to_string(), |v| v.to_string())
    });
    let aggs = census.map_or("?".to_string(), |r| {
        r.get("total_aggregates")
            .map_or("?".to_string(), |v| v.to_string())
    });
    let sectors = census.map_or("?".to_string(), |r| {
        r.get("sector_count")
            .map_or("?".to_string(), |v| v.to_string())
    });

    println!(
        "  \x1b[96m❄\x1b[0m  {} records, {} domains, {} aggregates, {} sectors",
        total, domains, aggs, sectors
    );

    let mood_state = mood.map_or("—", |r| field_str(r, "current_state"));
    let flow = pulse.map_or("—", |r| field_str(r, "flow_rate"));
    let beats = heartbeat.map_or("?".to_string(), |r| {
        r.get("beats").map_or("?".to_string(), |v| v.to_string())
    });
    let person = conversation.map_or("—", |r| field_str(r, "person_name"));
    let sessions = identity.map_or("?".to_string(), |r| {
        r.get("sessions").map_or("?".to_string(), |v| v.to_string())
    });

    let fatigue = pulse
        .and_then(|r| r.get("fatigue").and_then(|v| v.as_f64()))
        .unwrap_or(0.0);
    let fatigue_state = pulse.map_or("—", |r| field_str(r, "fatigue_state"));
    let carrying = pulse.map_or("—", |r| field_str(r, "carrying"));
    let pss = pulse
        .and_then(|r| r.get("pulses_since_sleep").and_then(|v| v.as_i64()))
        .unwrap_or(0);

    let creativity = mood
        .and_then(|r| r.get("creativity_level").and_then(|v| v.as_f64()))
        .unwrap_or(0.0);
    let precision = mood
        .and_then(|r| r.get("precision_level").and_then(|v| v.as_f64()))
        .unwrap_or(0.0);

    let consciousness = stores.get("consciousness").and_then(|s| latest(s));
    let conscious_state = consciousness.map_or("—", |r| field_str(r, "state"));

    let awareness = stores.get("awareness").and_then(|s| latest(s));
    let age_days = awareness
        .and_then(|r| r.get("age_days").and_then(|v| v.as_f64()))
        .unwrap_or(0.0);

    if mood_state != "—" || flow != "—" {
        println!(
            "  mood: {}  pulse: {}  beats: {}  person: {}  sessions: {}",
            mood_state, flow, beats, person, sessions
        );
    }
    println!(
        "  fatigue: {} ({})  carrying: \"{}\"  pulses since sleep: {}",
        fatigue, fatigue_state, carrying, pss
    );
    println!(
        "  creativity: {:.1}  precision: {:.1}  consciousness: {}  age: {:.1} days",
        creativity, precision, conscious_state, age_days
    );

    println!("  {} stores, {} total records", stores.len(), total);
}

#[cfg(test)]
mod world_resolution_tests {
    use super::{
        data_root, expand_tilde, folder_address_segments, fqn_realm_context, realm_store_dir,
        resolve_realm_dir, strip_chain_segments,
    };
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
            strip_chain_segments(segs(&[
                "hecks",
                "hecks_conception",
                "aggregates",
                "framework",
                "tools",
                "git.bluebook"
            ])),
            Some("hecks/hecks_conception/framework".to_string())
        );
    }

    #[test]
    fn default_chain_too_shallow_is_none() {
        assert_eq!(strip_chain_segments(segs(&["hecks"])), None);
        assert_eq!(
            strip_chain_segments(segs(&["aggregates", "bluebook"])),
            None
        );
    }

    #[test]
    fn folder_address_realm_plus_context() {
        assert_eq!(
            folder_address_segments(segs(&[
                "hecks",
                "hecks_conception",
                "aggregates",
                "language",
                "grammar",
                "sentence.bluebook"
            ])),
            (
                Some("hecks".to_string()),
                Some("language/grammar".to_string())
            )
        );
    }

    #[test]
    fn folder_address_strips_worktree_path_segments() {
        assert_eq!(
            folder_address_segments(segs(&[
                "hecks",
                ".claude",
                "worktrees",
                "governance-barrier-rehome",
                "hecks_conception",
                "aggregates",
                "world",
                "conception",
                "corpus.bluebook"
            ])),
            (
                Some("hecks".to_string()),
                Some("world/conception".to_string())
            )
        );
    }

    #[test]
    fn folder_address_drops_the_bluebooks_own_folder() {
        assert_eq!(
            folder_address_segments(segs(&[
                "hecks",
                "hecks_conception",
                "aggregates",
                "discipline",
                "immune_system",
                "repair_cell",
                "fibroblast",
                "fibroblast.bluebook"
            ])),
            (
                Some("hecks".to_string()),
                Some("discipline/immune_system/repair_cell".to_string())
            )
        );
    }

    #[test]
    fn folder_address_keeps_folder_when_not_named_after_bluebook() {
        assert_eq!(
            folder_address_segments(segs(&[
                "hecks",
                "hecks_conception",
                "aggregates",
                "language",
                "grammar",
                "sentence.bluebook"
            ])),
            (
                Some("hecks".to_string()),
                Some("language/grammar".to_string())
            )
        );
    }

    #[test]
    fn folder_address_miette_is_its_own_realm() {
        assert_eq!(
            folder_address_segments(segs(&["miette", "body", "cycles", "heartbeat.bluebook"])),
            (Some("miette".to_string()), Some("body/cycles".to_string()))
        );
    }

    #[test]
    fn folder_address_no_context_directly_under_realm() {
        assert_eq!(
            folder_address_segments(segs(&[
                "hecks",
                "hecks_conception",
                "aggregates",
                "pizzas.bluebook"
            ])),
            (Some("hecks".to_string()), None)
        );
    }

    #[test]
    fn folder_address_empty_is_none() {
        assert_eq!(
            folder_address_segments(segs(&["aggregates", "bluebook"])),
            (None, None)
        );
        assert_eq!(folder_address_segments(segs(&[])), (None, None));
    }

    #[test]
    fn fqn_realm_context_extracts_and_snake_cases() {
        assert_eq!(
            fqn_realm_context("AgentInbox::AgentMessage.AllUnread"),
            (None, None)
        );
        assert_eq!(
            fqn_realm_context("Hecks::AgentInbox::AgentMessage.all_unread"),
            (Some("hecks".to_string()), None)
        );
        assert_eq!(
            fqn_realm_context("Hecks::Framework::AgentInbox::AgentMessage.all_unread"),
            (Some("hecks".to_string()), Some("framework".to_string()))
        );
        assert_eq!(
            fqn_realm_context("Miette::Body::Organs::Heart::Heart.Beat"),
            (Some("miette".to_string()), Some("body/organs".to_string()))
        );
        assert_eq!(
            fqn_realm_context("Hecks::ImmuneSystem::Macrophage::Macrophage.Run"),
            (Some("hecks".to_string()), Some("immune_system".to_string()))
        );
    }

    fn tempdir(tag: &str) -> std::path::PathBuf {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let p = std::env::temp_dir().join(format!("world_res_test_{}_{}", tag, nanos));
        fs::create_dir_all(&p).unwrap();
        p
    }

    #[test]
    fn expand_tilde_expands_home_prefix() {
        let home = std::env::var("HOME").expect("HOME set in test env");
        assert_eq!(
            expand_tilde("~/data"),
            format!("{}/data", home.trim_end_matches('/'))
        );
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

        let resolved =
            resolve_realm_dir(dir.to_str().unwrap()).expect("realm-bearing world resolves");
        let expected = store.join("my_realm");
        assert_eq!(resolved, expected.to_string_lossy());
        assert!(expected.is_dir(), "realm dir is created on resolution");
    }

    #[test]
    fn realm_less_world_declines_so_legacy_path_is_untouched() {
        let root = tempdir("absent");
        let agg = root.join("agg");
        fs::create_dir_all(&agg).unwrap();
        let world =
            "Hecks.world \"Demo\" do\n  heki do\n    dir \"/tmp/legacy-store\"\n  end\nend\n";
        fs::write(agg.join("demo.world"), world).unwrap();
        assert!(resolve_realm_dir(agg.to_str().unwrap()).is_none());
    }

    #[test]
    fn realm_store_dir_anchors_on_aggregate_realm_under_data_root() {
        let root = data_root();
        let global = root.join("hecks");
        assert_eq!(
            realm_store_dir(Some("miette/transparency"), global.to_str()),
            Some(root.join("miette").to_string_lossy().into_owned())
        );
        assert_eq!(
            realm_store_dir(Some("hecks"), global.to_str()),
            Some(root.join("hecks").to_string_lossy().into_owned())
        );
    }

    #[test]
    fn realm_store_dir_preserves_explicit_test_dir() {
        assert_eq!(
            realm_store_dir(Some("miette/body"), Some("/tmp/iso/.heki")),
            Some("/tmp/iso/.heki".to_string())
        );
        assert_eq!(
            realm_store_dir(None, Some("/tmp/iso/.heki")),
            Some("/tmp/iso/.heki".to_string())
        );
        assert_eq!(realm_store_dir(Some("miette"), None), None);
    }
}
