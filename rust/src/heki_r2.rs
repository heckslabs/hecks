//! Heki R2 — Binary record storage on Cloudflare R2
//!
//! [antibody-exempt: rust/src/heki_r2.rs — kernel-floor binary
//!  record storage against a Cloudflare R2 bucket, sibling to
//!  rust/src/heki.rs (local filesystem). The bluebook DSL has no
//!  concept of "where to put bytes on a network" — this is the
//!  layer the Cloudflare Worker uses BEFORE bluebooks can be parsed.
//!  Retires alongside the broader i528 storehouse arc once the
//!  specializer can emit binding-shaped I/O.]
//!
//! Sibling of [`crate::heki`]. Identical wire format (HEKI magic +
//! u32 BE record count + zlib-compressed JSON), identical Store /
//! Record types, but persisted to an R2 object accessed through a
//! `worker::Bucket` binding instead of a local filesystem path.
//!
//! ## When this module compiles
//!
//! Cfg-gated to `target_arch = "wasm32"`. Inside the standalone
//! storehouse CLI (host process, target_arch = aarch64 / x86_64),
//! this module compiles to an empty stub — the CLI uses
//! [`crate::heki`] for its filesystem-backed storage. Inside the
//! Cloudflare Worker (compiled to wasm32-unknown-unknown), this
//! module IS the storage layer ; the `worker::Bucket` it depends
//! on only exists at that target.
//!
//! ## Usage (from the Worker)
//!
//!   let bucket = env.bucket("BIN_BUDDY_R2_BUCKET")?;
//!   let store  = heki_r2::read_record(&bucket, "heartbeat.heki").await?;
//!   heki_r2::upsert_record(&bucket, "heartbeat.heki", &attrs).await?;
//!   heki_r2::append_record(&bucket, "audit.heki", &attrs).await?;

#![cfg(target_arch = "wasm32")]

use crate::heki::{Record, Store};
use worker::Bucket;

// ---------------------------------------------------------------------------
// Wire format helpers — encode / decode the HEKI blob
// ---------------------------------------------------------------------------

/// Decode the HEKI wire format (magic + count + zlib JSON) into a Store.
/// Returns an empty Store when `data` is empty (the "object did not
/// exist" case the caller has already mapped to an empty Vec).
fn decode(data: &[u8]) -> Result<Store, String> {
    use std::io::Read as _;
    if data.is_empty() {
        return Ok(Store::new());
    }
    if data.len() < 8 {
        return Err("r2 blob too short".into());
    }
    if &data[0..4] != b"HEKI" {
        return Err("r2 blob bad magic".into());
    }
    let compressed = &data[8..];
    let mut decoder = flate2::read::ZlibDecoder::new(compressed);
    let mut json_str = String::new();
    decoder
        .read_to_string(&mut json_str)
        .map_err(|e| format!("r2 zlib decode: {}", e))?;
    serde_json::from_str(&json_str).map_err(|e| format!("r2 json decode: {}", e))
}

/// Encode a Store into the HEKI wire format. Symmetric with [`decode`] ;
/// the bytes produced by this function on the Worker are byte-for-byte
/// identical to what `heki::write_raw` produces on disk so a record
/// migrated between backends round-trips cleanly.
fn encode(store: &Store) -> Result<Vec<u8>, String> {
    use std::io::Write as _;
    let json = serde_json::to_string(store).map_err(|e| format!("r2 json encode: {}", e))?;
    let mut encoder = flate2::write::ZlibEncoder::new(Vec::new(), flate2::Compression::best());
    encoder
        .write_all(json.as_bytes())
        .map_err(|e| format!("r2 zlib compress: {}", e))?;
    let compressed = encoder.finish().map_err(|e| format!("r2 zlib finish: {}", e))?;
    let count = store.len() as u32;
    let mut out = Vec::with_capacity(8 + compressed.len());
    out.extend_from_slice(b"HEKI");
    out.extend_from_slice(&count.to_be_bytes());
    out.extend_from_slice(&compressed);
    Ok(out)
}

// ---------------------------------------------------------------------------
// Read — GET the object and decode
// ---------------------------------------------------------------------------

/// Fetch the R2 object at `key` and decode it into a Store. Returns an
/// empty Store when the object does not exist (mirrors [`crate::heki::read`]'s
/// missing-file semantics). Projection of `Heki.R2.Read`.
pub async fn read_record(bucket: &Bucket, key: &str) -> Result<Store, String> {
    let object = bucket
        .get(key)
        .execute()
        .await
        .map_err(|e| format!("r2 get {}: {}", key, e))?;
    let Some(object) = object else {
        return Ok(Store::new());
    };
    let Some(body) = object.body() else {
        return Ok(Store::new());
    };
    let bytes = body
        .bytes()
        .await
        .map_err(|e| format!("r2 read body {}: {}", key, e))?;
    decode(&bytes)
}

// ---------------------------------------------------------------------------
// Upsert — read, mutate in place by id (3 rules), write back
// ---------------------------------------------------------------------------

/// Insert or update a record by id, then PUT the full Store back to R2.
/// Matching rules mirror [`crate::heki::upsert`] exactly :
///
///   1. `attrs` carries an `id` AND the Store already has it → update in place.
///   2. No explicit id and the Store has exactly one record → singleton update.
///   3. Otherwise → create a new record (using the supplied id, or a
///      fresh uuid_v4).
///
/// Projection of `Heki.R2.Upsert`.
pub async fn upsert_record(
    bucket: &Bucket,
    key: &str,
    attrs: &Record,
) -> Result<Record, String> {
    let mut store = read_record(bucket, key).await?;
    let now = crate::clock::now_iso();

    let explicit_id = attrs.get("id").and_then(|v| v.as_str()).map(|s| s.to_string());

    // Rule 1 : targeted update by explicit id.
    if let Some(id) = &explicit_id {
        if let Some(existing) = store.get_mut(id) {
            for (k, v) in attrs {
                existing.insert(k.clone(), v.clone());
            }
            existing.insert("updated_at".into(), serde_json::Value::String(now));
            let rec = existing.clone();
            put_store(bucket, key, &store).await?;
            return Ok(rec);
        }
    }

    // Rule 2 : singleton in-place update.
    if store.len() == 1 && explicit_id.is_none() {
        if let Some((_id, existing)) = store.iter_mut().next() {
            for (k, v) in attrs {
                existing.insert(k.clone(), v.clone());
            }
            existing.insert("updated_at".into(), serde_json::Value::String(now));
            let rec = existing.clone();
            put_store(bucket, key, &store).await?;
            return Ok(rec);
        }
    }

    // Rule 3 : create.
    let id = explicit_id.unwrap_or_else(crate::util::uuid_v4);
    let mut rec = Record::new();
    rec.insert("id".into(), serde_json::Value::String(id.clone()));
    rec.insert("created_at".into(), serde_json::Value::String(now.clone()));
    rec.insert("updated_at".into(), serde_json::Value::String(now));
    for (k, v) in attrs {
        rec.insert(k.clone(), v.clone());
    }
    store.insert(id, rec.clone());
    put_store(bucket, key, &store).await?;
    Ok(rec)
}

// ---------------------------------------------------------------------------
// Append — fresh uuid, never updates an existing record
// ---------------------------------------------------------------------------

/// Add a new record with a freshly generated uuid_v4. Never updates
/// an existing record, even if `attrs` carries an `id`. Projection
/// of `Heki.R2.Append`.
pub async fn append_record(
    bucket: &Bucket,
    key: &str,
    attrs: &Record,
) -> Result<Record, String> {
    let mut store = read_record(bucket, key).await?;
    let id = crate::util::uuid_v4();
    let now = crate::clock::now_iso();

    let mut record = Record::new();
    record.insert("id".into(), serde_json::Value::String(id.clone()));
    record.insert("created_at".into(), serde_json::Value::String(now.clone()));
    record.insert("updated_at".into(), serde_json::Value::String(now));
    for (k, v) in attrs {
        record.insert(k.clone(), v.clone());
    }
    store.insert(id, record.clone());
    put_store(bucket, key, &store).await?;
    Ok(record)
}

// ---------------------------------------------------------------------------
// Internal — PUT the encoded Store back to R2
// ---------------------------------------------------------------------------

async fn put_store(bucket: &Bucket, key: &str, store: &Store) -> Result<(), String> {
    let body = encode(store)?;
    bucket
        .put(key, body)
        .execute()
        .await
        .map_err(|e| format!("r2 put {}: {}", key, e))?;
    Ok(())
}
