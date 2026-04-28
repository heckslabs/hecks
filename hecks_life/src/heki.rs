//! Heki — Binary record storage
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
//! (`hecks-life heki upsert/delete/append`) require an explicit
//! `--reason "<why>"` flag and pass `OutOfBand`. Direct callers
//! without context are a discipline gap — that's the structural
//! enforcement test_purity_shape's audit channel will eventually
//! react to.

use std::collections::HashMap;
use std::fs;
use std::io::Read as IoRead;
use std::io::Write as IoWrite;
use std::path::Path;
use std::time::SystemTime;

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
        .filter(|e| e.path().extension().map_or(false, |ext| ext == "heki"))
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
    let id = uuid_v4();
    let now = now_iso8601_internal();

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
    let now = now_iso8601_internal();

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
    let id = explicit_id.unwrap_or_else(uuid_v4);
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
        rec.insert("archived_at".into(), serde_json::Value::String(now_iso8601_internal()));
        write_raw(source_path, &store)?;
        // Archive append uses the same context — semantically the
        // same operation.
        let mut store = read(archive_path)?;
        let id_val = rec.get("id").and_then(|v| v.as_str()).map(|s| s.to_string())
            .unwrap_or_else(uuid_v4);
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

/// Generate a UUID v4 (random) without external dependencies.
pub fn uuid_v4() -> String {
    // Use system entropy via /dev/urandom or SystemTime fallback
    let mut bytes = [0u8; 16];
    if let Ok(mut f) = fs::File::open("/dev/urandom") {
        let _ = f.read_exact(&mut bytes);
    } else {
        // Fallback: hash system time
        let t = SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .unwrap_or_default();
        let seed = t.as_nanos();
        for (i, b) in bytes.iter_mut().enumerate() {
            *b = ((seed >> (i * 4)) & 0xff) as u8;
        }
    }
    // Set version 4 and variant bits
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    format!(
        "{:02x}{:02x}{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}",
        bytes[0], bytes[1], bytes[2], bytes[3],
        bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11],
        bytes[12], bytes[13], bytes[14], bytes[15]
    )
}

/// ISO 8601 timestamp without external dependencies.
pub fn now_iso8601_internal() -> String {
    let dur = SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .unwrap_or_default();
    let secs = dur.as_secs();

    // Days since epoch
    let mut days = (secs / 86400) as i64;
    let day_secs = (secs % 86400) as u32;
    let hours = day_secs / 3600;
    let mins = (day_secs % 3600) / 60;
    let s = day_secs % 60;

    // Civil date from days since 1970-01-01 (Euclidean affine algorithm)
    days += 719468;
    let era = if days >= 0 { days } else { days - 146096 } / 146097;
    let doe = (days - era * 146097) as u32;
    let yoe = (doe - doe/1460 + doe/36524 - doe/146096) / 365;
    let y = yoe as i64 + era * 400;
    let doy = doe - (365*yoe + yoe/4 - yoe/100);
    let mp = (5*doy + 2) / 153;
    let d = doy - (153*mp + 2)/5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };

    format!("{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z", y, m, d, hours, mins, s)
}

/// Public alias for now_iso8601_internal.
pub fn now_iso() -> String {
    now_iso8601_internal()
}

/// Seconds elapsed since an ISO 8601 timestamp.
pub fn seconds_since_iso(ts: &str) -> f64 {
    let now = SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs_f64();
    let epoch = parse_iso_to_epoch(ts);
    if epoch > 0.0 { now - epoch } else { 0.0 }
}

fn parse_iso_to_epoch(ts: &str) -> f64 {
    if ts.len() < 19 { return 0.0; }
    let y: i64 = ts[0..4].parse().unwrap_or(0);
    let m: u32 = ts[5..7].parse().unwrap_or(0);
    let d: u32 = ts[8..10].parse().unwrap_or(0);
    let h: u32 = ts[11..13].parse().unwrap_or(0);
    let mn: u32 = ts[14..16].parse().unwrap_or(0);
    let s: u32 = ts[17..19].parse().unwrap_or(0);
    let (y_adj, m_adj) = if m <= 2 { (y - 1, m + 9) } else { (y, m - 3) };
    let era = if y_adj >= 0 { y_adj } else { y_adj - 399 } / 400;
    let yoe = (y_adj - era * 400) as u32;
    let doy = (153 * m_adj + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146097 + doe as i64 - 719468;
    let mut epoch = days as f64 * 86400.0 + h as f64 * 3600.0 + mn as f64 * 60.0 + s as f64;
    let tz_part = &ts[19..];
    if tz_part.starts_with('+') || tz_part.starts_with('-') {
        let sign: f64 = if tz_part.starts_with('-') { 1.0 } else { -1.0 };
        let tz_h: f64 = tz_part[1..3].parse().unwrap_or(0.0);
        let tz_m: f64 = if tz_part.len() >= 6 { tz_part[4..6].parse().unwrap_or(0.0) } else { 0.0 };
        epoch += sign * (tz_h * 3600.0 + tz_m * 60.0);
    }
    epoch
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
    let being = stores.get("being").and_then(|s| latest(s));
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
