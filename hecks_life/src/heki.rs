//! Heki — Binary record storage
//!
//! Reads and writes .heki files: HEKI magic (4 bytes) + record count (u32 BE)
//! + zlib-compressed JSON. The JSON payload is a map of { id: String => record: Object }.
//!
//! Usage:
//!   let records = heki::read("information/mood.heki")?;
//!   heki::append("information/mood.heki", &attrs)?;
//!   heki::upsert("information/mood.heki", &attrs)?;

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

/// Write a store to a .heki file (HEKI + count + zlib-compressed JSON).
pub fn write(path: &str, store: &Store) -> Result<(), String> {
    let json = serde_json::to_string(store)
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
pub fn append(path: &str, attrs: &Record) -> Result<Record, String> {
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
    write(path, &store)?;
    Ok(record)
}

/// Upsert a singleton — update the first record or create one if empty.
pub fn upsert(path: &str, attrs: &Record) -> Result<Record, String> {
    let mut store = read(path)?;
    let now = now_iso8601_internal();

    let record = if let Some((_id, existing)) = store.iter_mut().next() {
        for (k, v) in attrs {
            existing.insert(k.clone(), v.clone());
        }
        existing.insert("updated_at".into(), serde_json::Value::String(now));
        existing.clone()
    } else {
        let id = uuid_v4();
        let mut rec = Record::new();
        rec.insert("id".into(), serde_json::Value::String(id.clone()));
        rec.insert("created_at".into(), serde_json::Value::String(now.clone()));
        rec.insert("updated_at".into(), serde_json::Value::String(now));
        for (k, v) in attrs {
            rec.insert(k.clone(), v.clone());
        }
        store.insert(id, rec.clone());
        rec
    };

    write(path, &store)?;
    Ok(record)
}

/// Delete a record by ID. Returns true if found and removed.
pub fn delete(path: &str, id: &str) -> Result<bool, String> {
    let mut store = read(path)?;
    let removed = store.remove(id).is_some();
    if removed {
        write(path, &store)?;
    }
    Ok(removed)
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

// ---------------------------------------------------------------------------
// Summary
// ---------------------------------------------------------------------------

/// Print a hydrate summary — vital signs from .heki stores.
pub fn print_summary(stores: &HashMap<String, Store>) {
    let total: usize = stores.values().map(|s| s.len()).sum();

    let mood = stores.get("mood").and_then(|s| latest(s));
    let pulse = stores.get("pulse").and_then(|s| latest(s));
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
