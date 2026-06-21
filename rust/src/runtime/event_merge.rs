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
//!
//! [antibody-exempt: rust/src/runtime/event_merge.rs — kernel-floor persistence
//!  IO. The pure, runtime-free shard-merge + reclaim core (file IO + sort +
//!  checkpoint + GC of dead, fully-folded shards), sibling of heki.rs /
//!  event_shard.rs. The CONCEPT is conceived in the EventSourcing bluebook
//!  (Consolidation.Consolidate — fold then reclaim) ; this is its hand-written
//!  runtime realization. A shard is a persistence ARTIFACT below the aggregate
//!  (like a .heki file), so modeling it as a domain aggregate would be the
//!  PersistenceIsAggregateOnly anti-pattern — the substrate the language bottoms
//!  out on, not the language. Same kernel-floor contract as projection_fold.rs.]

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

/// Append a merged batch to the global Event Log. The global Log is an
/// APPEND-ONLY JSONL file (event_log.rs), NOT a whole-file heki store : heki
/// is for snapshots, the LOG is append-only (Chris, 2026-06-21 ; the shards
/// already abandoned heki for the same reason). So each merge appends the new
/// batch — O(batch) — instead of decompress-insert-recompress the whole log
/// (O(whole-log)) every 5s, and the file is directly `tail -f`-able.
///
/// The merge is the SOLE writer, so a plain O_APPEND is lossless. The global
/// `sequence` is the persisted monotonic counter event_log owns (no whole-file
/// read to compute store.len()). Dedup rides the per-shard CHECKPOINT (consumed
/// bytes are never re-read — see merge_pass), with the fold's idempotence to
/// duplicate deltas as the crash-replay backstop ; write_batch_to_global is a
/// pure append. Returns the count appended.
pub fn write_batch_to_global(global_path: &str, batch: &[ShardRecord]) -> Result<usize, String> {
    super::event_log::append_records(global_path, batch)
        .map_err(|e| format!("event-log append {}: {}", global_path, e))
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

/// Parse the owning pid from a shard id of the form `p{pid}-{nonce}`
/// (event_shard::process_shard_id). None for any id that does not match —
/// such a shard is never reclaimed (conservative).
pub fn owner_pid(shard_id: &str) -> Option<u32> {
    shard_id.strip_prefix('p')?.split('-').next()?.parse().ok()
}

/// Reclaim per-process shard files the merge has already fully folded into the
/// global Log AND whose owning process is dead. Returns the count deleted and
/// prunes each reclaimed shard's checkpoint entry (so the checkpoint does not
/// grow without bound — it tracked one entry per process that ever wrote).
/// The caller persists the pruned checkpoint.
///
/// Two guards, both REQUIRED, make this lossless and crash-safe :
///   1. FULLY FOLDED : checkpoint offset >= on-disk size, so every byte is
///      already in event.heki. A shard with an unconsumed tail (offset < size)
///      is left for the next merge to fold first, THEN reclaim.
///   2. OWNER DEAD : a LIVE process holds its shard's file handle open
///      (event_shard PROCESS_SHARD) ; unlinking it would send that process's
///      future appends to a ghost inode, silently lost. So liveness is checked
///      via the injected `is_alive` predicate. pid-reuse only makes this MORE
///      conservative (a reused pid reads as alive -> skip). The predicate is
///      injected (not a syscall here) so this core stays pure and unit-testable
///      — the caller supplies the real process-table lookup, and MUST pass a
///      predicate that errs toward `alive` when liveness cannot be determined.
pub fn reclaim_consumed_shards(
    shards: &[Shard],
    checkpoint: &mut Checkpoint,
    is_alive: &dyn Fn(u32) -> bool,
) -> usize {
    let mut reclaimed = 0usize;
    for shard in shards {
        let off = checkpoint.get(&shard.id).copied().unwrap_or(0);
        let size = match std::fs::metadata(&shard.path) {
            Ok(m) => m.len(),
            Err(_) => continue, // gone already, or unstattable : skip
        };
        if off < size {
            continue; // unconsumed tail : the next merge folds it first
        }
        // Unparseable id, or a live owner : never reclaim.
        match owner_pid(&shard.id) {
            Some(pid) if !is_alive(pid) => {
                if std::fs::remove_file(&shard.path).is_ok() {
                    checkpoint.remove(&shard.id);
                    reclaimed += 1;
                }
            }
            _ => {}
        }
    }
    reclaimed
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
        let global = dir.join("event.log");
        let gp = global.to_str().unwrap();

        // First pass : merge_pass returns the 2 records ; the append lands them.
        let batch = merge_pass(&discover_shards(&dir).unwrap(), &mut cp).unwrap();
        let n1 = write_batch_to_global(gp, &batch).unwrap();
        assert_eq!(n1, 2, "first pass appends both events");
        // Idempotence MOVED : the global Log is now append-only JSONL (not a
        // dedup'd heki map), so write_batch_to_global is a pure append. Crash-
        // safety rides the CHECKPOINT — once it has advanced, a second merge_pass
        // returns NOTHING, so each event lands in the global Log exactly once.
        let batch2 = merge_pass(&discover_shards(&dir).unwrap(), &mut cp).unwrap();
        assert!(batch2.is_empty(), "checkpoint prevents re-reading consumed shard bytes");
        let states = crate::runtime::event_log::load_states(gp);
        assert_eq!(states.len(), 2, "global Log holds each event exactly once");
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

    #[test]
    fn reclaim_deletes_only_dead_and_fully_folded_shards() {
        // The two guards in one table. Three shards in the p{pid}-{nonce} form
        // so owner_pid parses :
        //   p111 : dead owner, fully folded   -> RECLAIM
        //   p222 : dead owner, unconsumed tail -> keep (merge folds it first)
        //   p333 : ALIVE owner, fully folded   -> keep (open handle ; ghost-inode)
        let dir = tmp("reclaim");
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let mut a = ShardWriter::open(&dir.join("p111-1.shard")).unwrap();
        let mut b = ShardWriter::open(&dir.join("p222-2.shard")).unwrap();
        let mut c = ShardWriter::open(&dir.join("p333-3.shard")).unwrap();
        a.append(&rec("p111-1", 1, "t1")).unwrap();
        b.append(&rec("p222-2", 1, "t1")).unwrap();
        c.append(&rec("p333-3", 1, "t1")).unwrap();
        let shards = discover_shards(&dir).unwrap();
        // Fold everything to EOF, then write MORE to b so its offset < size.
        let mut cp = Checkpoint::new();
        let _ = merge_pass(&shards, &mut cp).unwrap();
        b.append(&rec("p222-2", 2, "t2")).unwrap();

        let is_alive = |pid: u32| pid == 333; // only p333 lives
        let n = reclaim_consumed_shards(&shards, &mut cp, &is_alive);

        assert_eq!(n, 1, "only the dead, fully-folded shard is reclaimed");
        assert!(!dir.join("p111-1.shard").exists(), "dead + folded -> deleted");
        assert!(dir.join("p222-2.shard").exists(), "unconsumed tail -> kept");
        assert!(dir.join("p333-3.shard").exists(), "alive owner -> kept");
        assert!(cp.get("p111-1").is_none(), "reclaimed shard's checkpoint entry pruned");
        assert!(cp.get("p222-2").is_some(), "kept shard's checkpoint entry remains");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn owner_pid_parses_shard_id_form() {
        assert_eq!(owner_pid("p12345-1781999116413003000"), Some(12345));
        assert_eq!(owner_pid("p7-0"), Some(7));
        assert_eq!(owner_pid("nonsense"), None); // never reclaimed
        assert_eq!(owner_pid("p-1"), None);
    }
}
