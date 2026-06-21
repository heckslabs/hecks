//! event_log — the append-only JSONL substrate for the GLOBAL Event Log.
//!
//! Chris's architectural call (2026-06-21) : heki is a keyed map with whole-file
//! read-modify-write — the right home for SNAPSHOTS / current-state, the WRONG
//! fit for an append-only ordered LOG (the per-process shards already abandoned
//! heki for exactly this reason — see event_shard.rs). So the merged global Log
//! is its OWN append-only JSONL file (`event.log`), NOT a heki store : one Event
//! per line, appended O(batch) per merge (never the O(whole-log) zlib rewrite the
//! heki global cost), and directly `tail -f`-able — the substrate you can watch.
//!
//! `persisted_by("AppendLog")` therefore OWNS its format end-to-end : the shard
//! WRITE (event_shard) and this global READ/APPEND. heki never sees the Log file.
//!
//! Single-writer : only the consolidate driver appends here (the merge), so a
//! plain O_APPEND is lossless — the >4KB atomicity caveat that drove the shard
//! design applies to CONCURRENT writers, and there is exactly one. The global
//! sequence is a persisted monotonic counter (`.seq` sidecar) the merge owns ;
//! dedup rides the per-shard checkpoint (consumed bytes are never re-read), with
//! the fold's idempotence to duplicate deltas as the crash-replay backstop.
//!
//! [antibody-exempt: rust/src/runtime/event_log.rs — kernel-floor persistence IO.
//!  The append-only JSONL substrate for the global Event Log, sibling of heki.rs /
//!  event_shard.rs / event_merge.rs. The CONCEPT is conceived in the EventSourcing
//!  bluebook (the Log's append-and-replay surface ; persisted_by("AppendLog")) ;
//!  this is its hand-written runtime realization. A log file is a persistence
//!  ARTIFACT below the aggregate (like a .heki file), so modeling it as a domain
//!  aggregate would be the PersistenceIsAggregateOnly anti-pattern.]

use super::AggregateState;
use std::io::Write;
use std::path::Path;

/// The global Event Log path : `<dir>/<context_snake>/event.log`. Mirrors
/// heki::path_for's directory shape but with the `.log` extension — an
/// append-only JSONL file, not a whole-file heki store.
pub fn global_path(dir: &str, context: Option<&str>) -> String {
    match context {
        Some(ctx) if !ctx.is_empty() => {
            format!("{}/{}/event.log", dir, crate::util::snake_case(ctx))
        }
        _ => format!("{}/event.log", dir),
    }
}

/// The sequence sidecar : `<event.log>.seq`, holding the next global sequence.
fn seq_path(global: &str) -> String {
    format!("{}.seq", global)
}

/// The next global sequence to assign. Default 1 when the sidecar is absent
/// (a fresh log). Single-writer (the merge), so no locking.
pub fn read_next_seq(global: &str) -> u64 {
    std::fs::read_to_string(seq_path(global))
        .ok()
        .and_then(|s| s.trim().parse().ok())
        .unwrap_or(1)
}

/// Persist the next global sequence after a durable append.
pub fn write_next_seq(global: &str, n: u64) {
    let _ = std::fs::write(seq_path(global), n.to_string());
}

/// File mtime of the log, for the AppendLog reader's staleness check.
pub fn mtime(global: &str) -> Option<std::time::SystemTime> {
    std::fs::metadata(global).and_then(|m| m.modified()).ok()
}

/// Append a batch of Event records as JSONL lines, stamping each with the next
/// authoritative GLOBAL sequence (overwriting the per-process sequence the shard
/// carried — single-writer model). Returns the count appended. The `.seq` sidecar
/// is advanced only after the durable append, so a crash leaves the counter at or
/// behind the file (a replay re-appends ; the fold absorbs the duplicate delta).
pub fn append_records(
    global: &str,
    batch: &[super::event_shard::ShardRecord],
) -> std::io::Result<usize> {
    if batch.is_empty() {
        return Ok(0);
    }
    if let Some(parent) = Path::new(global).parent() {
        std::fs::create_dir_all(parent)?;
    }
    // The log byte-length BEFORE this append — the base for the new lines' byte
    // offsets and the index's self-heal check (event_log_index).
    let l0 = std::fs::metadata(global).map(|m| m.len()).unwrap_or(0);
    let mut next = read_next_seq(global);
    let mut buf = String::new();
    // (start_offset, aggregate_name) for each new line, for the offset index.
    let mut entries: Vec<(u64, String)> = Vec::new();
    let mut offset = l0;
    for rec in batch {
        // The line IS the Event record : the shard's opaque `event` map, stamped
        // with the heki-style id (event_id), the origin shard, and the global seq.
        let mut r = rec.event.clone();
        r.insert("id".into(), serde_json::Value::String(rec.event_id.clone()));
        r.insert("shard".into(), serde_json::Value::String(rec.shard.clone()));
        let mut seqobj = serde_json::Map::new();
        seqobj.insert("value".into(), serde_json::Value::Number(next.into()));
        r.insert("sequence".into(), serde_json::Value::Object(seqobj));
        let name = r
            .get(super::event_log_index::INDEXED_FIELD)
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        let line = serde_json::Value::Object(r).to_string();
        entries.push((offset, name));
        offset += line.len() as u64 + 1;
        buf.push_str(&line);
        buf.push('\n');
        next += 1;
    }
    let mut f = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(global)?;
    f.write_all(buf.as_bytes())?;
    write_next_seq(global, next);
    // Maintain the offset index AFTER the log bytes are durable ; record_appends
    // writes its commit marker last and self-heals if it was out of sync.
    super::event_log_index::record_appends(global, l0, &entries, l0 + buf.len() as u64);
    Ok(batch.len())
}

/// Hydrate one parsed JSONL object into an `AggregateState` (id = event_id ;
/// the heki dedup `id` key is dropped, the `event_id` field carries it). The
/// single per-line conversion shared by the full `load_states` read and the
/// filtered `event_log_query` scan — so a filtered candidate is byte-for-byte
/// the state a full hydrate would have produced (the parity contract).
pub(super) fn state_from_obj(
    obj: &serde_json::Map<String, serde_json::Value>,
) -> AggregateState {
    let id = obj
        .get("id")
        .or_else(|| obj.get("event_id"))
        .and_then(|x| x.as_str())
        .unwrap_or("")
        .to_string();
    let mut st = AggregateState::new(&id);
    for (k, val) in obj {
        if k == "id" {
            continue; // the heki dedup key ; the event_id field carries it
        }
        st.set(k, super::json_to_value_recursive(val));
    }
    st
}

/// Load every Event record from the JSONL log into `AggregateState` (id =
/// event_id). Missing file -> empty. A malformed line is skipped (best-effort
/// read view ; a torn line is a single-writer impossibility, so this only guards
/// a partial trailing write in flight).
pub fn load_states(global: &str) -> Vec<AggregateState> {
    let text = match std::fs::read_to_string(global) {
        Ok(t) => t,
        Err(_) => return Vec::new(),
    };
    let mut out = Vec::new();
    for line in text.lines() {
        if line.trim().is_empty() {
            continue;
        }
        let v: serde_json::Value = match serde_json::from_str(line) {
            Ok(v) => v,
            Err(_) => continue,
        };
        let obj = match v.as_object() {
                Some(o) => o,
                None => continue,
            };
            out.push(state_from_obj(obj));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use super::super::event_shard::ShardRecord;

    fn rec(shard: &str, seq: u64, field: &str, value: &str) -> ShardRecord {
        let mut event = serde_json::Map::new();
        event.insert("event_id".into(), serde_json::Value::String(format!("{}-{}", shard, seq)));
        event.insert("aggregate_name".into(), serde_json::Value::String("Order".into()));
        event.insert("aggregate_id".into(), serde_json::Value::String("o1".into()));
        let mut delta = serde_json::Map::new();
        delta.insert("field".into(), serde_json::Value::String(field.into()));
        delta.insert("value".into(), serde_json::Value::String(value.into()));
        event.insert("delta".into(), serde_json::Value::Object(delta));
        ShardRecord { shard: shard.into(), seq, ts: "t".into(), event_id: format!("{}-{}", shard, seq), event }
    }

    fn tmp(name: &str) -> String {
        std::env::temp_dir()
            .join(format!("event_log_{}_{}/event.log", std::process::id(), name))
            .to_string_lossy()
            .into_owned()
    }

    #[test]
    fn append_assigns_monotonic_global_sequence_and_reads_back() {
        let g = tmp("append");
        let _ = std::fs::remove_dir_all(Path::new(&g).parent().unwrap());
        // Two appends ; the second continues the sequence (no whole-file read).
        append_records(&g, &[rec("a", 1, "status", "pending"), rec("a", 2, "status", "paid")]).unwrap();
        append_records(&g, &[rec("b", 1, "status", "shipped")]).unwrap();
        let states = load_states(&g);
        assert_eq!(states.len(), 3, "every appended record reads back");
        let seqs: Vec<i64> = states.iter().map(|s| match s.get("sequence") {
            super::super::Value::Map(m) => m.get("value").and_then(|v| v.as_int()).unwrap_or(0),
            _ => 0,
        }).collect();
        let mut sorted = seqs.clone();
        sorted.sort();
        assert_eq!(sorted, vec![1, 2, 3], "global sequence is monotonic across appends");
        // The nested delta survives the round-trip (not collapsed).
        let s0 = &states[0];
        match s0.get("delta") {
            super::super::Value::Map(m) => {
                assert!(m.get("field").and_then(|v| v.as_str()).is_some());
            }
            _ => panic!("delta must round-trip as a Map"),
        }
        let _ = std::fs::remove_dir_all(Path::new(&g).parent().unwrap());
    }
}
