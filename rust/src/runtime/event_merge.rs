//! event_merge — the merge half of the out-of-process Event Log (slice 2).
//!
//! The shards-plus-merge topology : N dispatch processes each single-write
//! their own append-only shard (event_shard.rs) ; ONE merge daemon tails
//! every shard and folds them into the global ordered `event.heki`. Because
//! the merge daemon is the SOLE writer of the global log, the global store
//! may use ordinary whole-file heki — the clobber that started all this only
//! ever bit CONCURRENT writers, and here there is exactly one.
//!
//! A merge PASS : for each shard, read every record written since that
//! shard's checkpoint offset ; collect across all shards ; sort the batch by
//! the total-order key (ts, shard, seq) ; return it with the advanced
//! checkpoint. The daemon then appends the sorted batch to the global log
//! (assigning the authoritative monotonic global sequence at append) and
//! persists the checkpoint. Per-shard byte offsets make every pass resume
//! exactly where the last left off — no event read twice, none skipped.
//!
//! This module is the pure, runtime-free core (file IO + sort + checkpoint),
//! so the losslessness proof — 30 concurrent writers, 30/30 events survive,
//! the case the old whole-file Event repo dropped to 13/30 — is a direct
//! unit test. The `storehouse merge` daemon wrapper + the record_event_append
//! rewiring + the gate flip are the following slices.

use super::event_shard::{read_from, ShardRecord};
use std::collections::HashMap;
use std::path::{Path, PathBuf};

/// Per-shard byte-offset high-water marks : shard id -> next unread offset.
pub type Checkpoint = HashMap<String, u64>;

/// One shard to merge : its stable id (the checkpoint key) and its path.
pub struct Shard {
    pub id: String,
    pub path: PathBuf,
}

/// Discover every `*.shard` file in `dir` as a Shard (id = file stem). Empty
/// (not an error) when the dir is absent — the daemon may start before any
/// process has written a shard.
pub fn discover_shards(dir: &Path) -> std::io::Result<Vec<Shard>> {
    let mut shards = Vec::new();
    let entries = match std::fs::read_dir(dir) {
        Ok(e) => e,
        Err(ref e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(shards),
        Err(e) => return Err(e),
    };
    for entry in entries {
        let path = entry?.path();
        if path.extension().and_then(|x| x.to_str()) == Some("shard") {
            if let Some(stem) = path.file_stem().and_then(|x| x.to_str()) {
                shards.push(Shard { id: stem.to_string(), path });
            }
        }
    }
    // Stable discovery order so a pass over identical state is deterministic.
    shards.sort_by(|a, b| a.id.cmp(&b.id));
    Ok(shards)
}

/// Run one merge pass over `shards`, advancing `checkpoint` in place. Returns
/// every record written since the last pass, sorted by the total-order key
/// (ts, shard, seq). The caller appends this batch to the global log and
/// persists the (now advanced) checkpoint.
pub fn merge_pass(shards: &[Shard], checkpoint: &mut Checkpoint) -> std::io::Result<Vec<ShardRecord>> {
    let mut batch = Vec::new();
    for shard in shards {
        let from = checkpoint.get(&shard.id).copied().unwrap_or(0);
        let (records, new_off) = read_from(&shard.path, from)?;
        batch.extend(records);
        checkpoint.insert(shard.id.clone(), new_off);
    }
    batch.sort_by(|a, b| {
        a.ts.cmp(&b.ts)
            .then(a.shard.cmp(&b.shard))
            .then(a.seq.cmp(&b.seq))
    });
    Ok(batch)
}

/// Load a checkpoint map from a plain JSON file (single-writer : the merge
/// daemon). Missing file -> empty checkpoint (a fresh merge).
pub fn load_checkpoint(path: &Path) -> std::io::Result<Checkpoint> {
    let text = match std::fs::read_to_string(path) {
        Ok(t) => t,
        Err(ref e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Checkpoint::new()),
        Err(e) => return Err(e),
    };
    let v: serde_json::Value = serde_json::from_str(&text)
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e.to_string()))?;
    let mut cp = Checkpoint::new();
    if let Some(obj) = v.as_object() {
        for (k, val) in obj {
            if let Some(n) = val.as_u64() {
                cp.insert(k.clone(), n);
            }
        }
    }
    Ok(cp)
}

/// Append a merged batch to the global Event log, IDEMPOTENTLY by event_id.
/// The merge daemon is the SOLE writer of the global store, so whole-file heki
/// is safe here (the clobber only ever bit concurrent writers). Idempotency is
/// the crash-safety property : a record whose event_id is already in the global
/// store is skipped, so a batch REPLAYED after a crash (global write durable
/// but checkpoint not yet saved) produces NO duplicate. The global `sequence`
/// is assigned HERE — store.len()+1, the authoritative monotonic order — not by
/// the Event aggregate (single-writer model ; slice 3 must not re-add count+1).
/// Returns the count of newly-written (non-duplicate) records.
pub fn write_batch_to_global(global_path: &str, batch: &[ShardRecord]) -> Result<usize, String> {
    use serde_json::Value;
    let mut store = crate::heki::read(global_path)?;
    let mut written = 0usize;
    for rec in batch {
        if store.contains_key(&rec.event_id) {
            continue; // idempotent : already merged (crash-replay dedup)
        }
        let seq = store.len() as i64 + 1; // append-only -> len == max sequence
        // The event payload IS the record : write the serialized Event
        // verbatim (the true nested shape), then stamp the heki key (id), the
        // origin shard, and the AUTHORITATIVE global sequence — overwriting the
        // per-process sequence the writer carried (single-writer model).
        let mut r: crate::heki::Record = rec.event.clone().into_iter().collect();
        r.insert("id".into(), Value::String(rec.event_id.clone())); // heki dedup key
        r.insert("shard".into(), Value::String(rec.shard.clone()));
        let mut seqobj = serde_json::Map::new();
        seqobj.insert("value".into(), Value::Number(seq.into()));
        r.insert("sequence".into(), Value::Object(seqobj));
        store.insert(rec.event_id.clone(), r);
        written += 1;
    }
    crate::heki::write(
        global_path,
        &store,
        crate::heki::WriteContext::OutOfBand { reason: "event-log-merge" },
    )?;
    Ok(written)
}

/// Persist a checkpoint map as JSON. Written by the sole merge daemon, so a
/// plain whole-file write is safe.
pub fn save_checkpoint(path: &Path, cp: &Checkpoint) -> std::io::Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let mut m = serde_json::Map::new();
    for (k, off) in cp {
        m.insert(k.clone(), serde_json::Value::Number((*off).into()));
    }
    std::fs::write(path, serde_json::Value::Object(m).to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::runtime::event_shard::{ShardWriter, ShardRecord};

    fn rec(shard: &str, seq: u64, ts: &str) -> ShardRecord {
        let mut event = serde_json::Map::new();
        event.insert("event_id".into(), serde_json::Value::String(format!("{}-{}", shard, seq)));
        event.insert("aggregate_name".into(), serde_json::Value::String("Order".into()));
        event.insert("aggregate_id".into(), serde_json::Value::String(format!("o-{}", seq)));
        event.insert("value".into(), serde_json::Value::String("pending".into()));
        ShardRecord {
            shard: shard.into(),
            seq,
            ts: ts.into(),
            event_id: format!("{}-{}", shard, seq),
            event,
        }
    }

    fn tmp(name: &str) -> PathBuf {
        std::env::temp_dir().join(format!("event_merge_{}_{}", std::process::id(), name))
    }

    #[test]
    fn merge_pass_sorts_by_total_order_key() {
        let dir = tmp("sort");
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        // Two shards, interleaved timestamps ; the merge must order by ts.
        let mut a = ShardWriter::open(&dir.join("a.shard")).unwrap();
        let mut b = ShardWriter::open(&dir.join("b.shard")).unwrap();
        a.append(&rec("a", 1, "2026-06-20T10:00:01Z")).unwrap();
        a.append(&rec("a", 2, "2026-06-20T10:00:03Z")).unwrap();
        b.append(&rec("b", 1, "2026-06-20T10:00:02Z")).unwrap();
        let shards = discover_shards(&dir).unwrap();
        let mut cp = Checkpoint::new();
        let batch = merge_pass(&shards, &mut cp).unwrap();
        let order: Vec<&str> = batch.iter().map(|r| r.event_id.as_str()).collect();
        assert_eq!(order, vec!["a-1", "b-1", "a-2"]); // by ts: 01, 02, 03
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn merge_pass_resumes_no_replay_no_skip() {
        let dir = tmp("resume");
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let mut a = ShardWriter::open(&dir.join("a.shard")).unwrap();
        a.append(&rec("a", 1, "t1")).unwrap();
        let mut cp = Checkpoint::new();
        let first = merge_pass(&discover_shards(&dir).unwrap(), &mut cp).unwrap();
        assert_eq!(first.len(), 1);
        // More appends ; the next pass sees ONLY the new ones (no replay).
        a.append(&rec("a", 2, "t2")).unwrap();
        a.append(&rec("a", 3, "t3")).unwrap();
        let second = merge_pass(&discover_shards(&dir).unwrap(), &mut cp).unwrap();
        assert_eq!(second.iter().map(|r| r.seq).collect::<Vec<_>>(), vec![2, 3]);
        // A pass with nothing new yields nothing (no skip, no replay).
        let third = merge_pass(&discover_shards(&dir).unwrap(), &mut cp).unwrap();
        assert!(third.is_empty());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn checkpoint_round_trips() {
        let path = tmp("cp.json");
        let _ = std::fs::remove_file(&path);
        let mut cp = Checkpoint::new();
        cp.insert("a".into(), 128);
        cp.insert("b".into(), 4096);
        save_checkpoint(&path, &cp).unwrap();
        let loaded = load_checkpoint(&path).unwrap();
        assert_eq!(loaded.get("a"), Some(&128));
        assert_eq!(loaded.get("b"), Some(&4096));
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn replayed_batch_does_not_duplicate_in_global_log() {
        // CRASH-SAFETY. The daemon writes the global log BEFORE saving the
        // checkpoint ; if it crashes in between, the SAME batch is merged
        // again next boot. Idempotency by event_id must make that replay a
        // no-op — each event in the global log exactly once, never twice.
        let dir = tmp("crash");
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let mut w = ShardWriter::open(&dir.join("a.shard")).unwrap();
        w.append(&rec("a", 1, "t1")).unwrap();
        w.append(&rec("a", 2, "t2")).unwrap();
        let mut cp = Checkpoint::new();
        let batch = merge_pass(&discover_shards(&dir).unwrap(), &mut cp).unwrap();
        let global = dir.join("event.heki");
        let gp = global.to_str().unwrap();

        let n1 = write_batch_to_global(gp, &batch).unwrap();
        assert_eq!(n1, 2, "first write lands both events");
        // SIMULATE CRASH : checkpoint was NOT saved, so the same batch replays.
        let n2 = write_batch_to_global(gp, &batch).unwrap();
        assert_eq!(n2, 0, "replayed batch writes nothing new (idempotent by event_id)");
        let store = crate::heki::read(gp).unwrap();
        assert_eq!(store.len(), 2, "global log holds each event exactly once");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn thirty_concurrent_writers_lose_nothing() {
        // THE PROOF. 30 processes-worth of concurrent writers, each the SOLE
        // writer of its OWN shard, 50 events each. The merge must recover all
        // 30*50 = 1500 — the case the old whole-file Event repo dropped to
        // 13/30. Single-writer-per-shard is what buys losslessness.
        let dir = tmp("concurrent");
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        const WRITERS: u64 = 30;
        const PER: u64 = 50;
        let handles: Vec<_> = (0..WRITERS).map(|w| {
            let dir = dir.clone();
            std::thread::spawn(move || {
                let id = format!("p{:02}", w);
                let mut writer = ShardWriter::open(&dir.join(format!("{}.shard", id))).unwrap();
                for s in 1..=PER {
                    let ts = format!("2026-06-20T10:{:02}:{:02}Z", w % 60, s % 60);
                    writer.append(&rec(&id, s, &ts)).unwrap();
                }
            })
        }).collect();
        for h in handles {
            h.join().unwrap();
        }
        let mut cp = Checkpoint::new();
        let batch = merge_pass(&discover_shards(&dir).unwrap(), &mut cp).unwrap();
        assert_eq!(batch.len() as u64, WRITERS * PER, "every concurrent event must survive");
        // And they are unique (no torn/duplicated records).
        let mut ids: Vec<&str> = batch.iter().map(|r| r.event_id.as_str()).collect();
        ids.sort();
        ids.dedup();
        assert_eq!(ids.len() as u64, WRITERS * PER, "no duplicates, no corruption");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
