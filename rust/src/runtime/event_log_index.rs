//! event_log_index — the offset index for the append-only Event Log (Phase 3)
//!
//! Maps the Log's primary partition key (`aggregate_name`) to the byte offsets
//! of its events in `event.log`, so `Event.Replay(name)` SEEKS to its events
//! instead of streaming the whole Log.
//!
//! SAFE BY CONSTRUCTION — no false negative is possible :
//!   * The index is maintained ONLY by the single writer (the consolidate
//!     merge, via event_log::append_records). Readers never write it, so there
//!     is no reader-vs-reader race.
//!   * `event.log.idx.len` is the COMMIT MARKER, written LAST (after the log
//!     append and after the index entries). It records the log byte-length the
//!     index is complete through.
//!   * A reader uses the index ONLY when `idx.len == current log length` — i.e.
//!     the index is provably complete. After a crash (log appended, marker not
//!     yet advanced) the lengths differ, so readers fall back to the full
//!     streaming scan (always correct) until the next append self-heals.
//!   * The writer self-heals : if the marker doesn't match the pre-append log
//!     length (a prior crash, or a deleted index file), it REBUILDS the whole
//!     index from the log before appending the new entries.
//!
//! Format : `event.log.idx2` is one `<byte_offset>\t<aggregate_name>\t<sequence>`
//! line per event, in log order ; `event.log.idx2.len` holds a single integer
//! (the commit marker). The name column backs `Replay`'s Eq-by-name seek ; the
//! sequence column (ascending, since log order == sequence order) backs the
//! sequence-range seek (`complete_offsets_in_seq_range`, binary-searchable).
//! The `.idx2` filename supersedes the legacy 2-column `.idx` (see idx_path).

use std::io::{BufRead, Write};

/// The Log field the index partitions on — the Replay key.
pub const INDEXED_FIELD: &str = "aggregate_name";

// `.idx2` (NOT `.idx`) : the index format gained a 3rd column (sequence) for the
// sequence-range seek. Bumping the filename is the migration — the legacy 2-col
// `.idx` is simply never read, so it can't be mis-parsed ; the new `.idx2` is
// absent on first run, so record_appends rebuilds it from the log (the existing
// self-heal path) and stamps its marker last. Safe-by-construction, no data op.
fn idx_path(global: &str) -> String {
    format!("{}.idx2", global)
}

fn len_path(global: &str) -> String {
    format!("{}.idx2.len", global)
}

fn log_len(global: &str) -> u64 {
    std::fs::metadata(global).map(|m| m.len()).unwrap_or(0)
}

fn read_marker(global: &str) -> u64 {
    std::fs::read_to_string(len_path(global))
        .ok()
        .and_then(|s| s.trim().parse().ok())
        .unwrap_or(0)
}

fn write_marker(global: &str, n: u64) {
    let _ = std::fs::write(len_path(global), n.to_string());
}

/// The indexed field's value from a raw JSONL line, or None if absent / the
/// line isn't a JSON object (such a line simply isn't indexed — it can't match
/// an aggregate_name query anyway).
fn indexed_value(line: &str) -> Option<String> {
    let v: serde_json::Value = serde_json::from_str(line).ok()?;
    v.as_object()?
        .get(INDEXED_FIELD)?
        .as_str()
        .map(|s| s.to_string())
}

/// The sequence value from a raw JSONL line — the nested `{"sequence":{"value":N}}`
/// the merge stamps. None if absent / unparseable (a line with no sequence gets 0
/// in the rebuilt index ; it can't meaningfully match a sequence-range query).
fn indexed_sequence(line: &str) -> Option<u64> {
    let v: serde_json::Value = serde_json::from_str(line).ok()?;
    v.as_object()?.get("sequence")?.as_object()?.get("value")?.as_u64()
}

/// Rebuild the entire index from `log[0..up_to]`, then stamp the marker. Used by
/// the writer when the index is out of sync (crash gap, missing file, first
/// build). O(log) but only on the cold path ; steady-state append is O(batch).
fn rebuild(global: &str, up_to: u64) {
    let mut idx_buf = String::new();
    if let Ok(file) = std::fs::File::open(global) {
        let mut reader = std::io::BufReader::new(file);
        let mut offset: u64 = 0;
        let mut line = String::new();
        while offset < up_to {
            line.clear();
            let n = match reader.read_line(&mut line) {
                Ok(0) => break,
                Ok(n) => n,
                Err(_) => break,
            };
            if let Some(name) = indexed_value(line.trim_end()) {
                let seq = indexed_sequence(line.trim_end()).unwrap_or(0);
                idx_buf.push_str(&format!("{}\t{}\t{}\n", offset, name, seq));
            }
            offset += n as u64;
        }
    }
    let _ = std::fs::write(idx_path(global), idx_buf);
    write_marker(global, up_to);
}

/// Single-writer hook : record an append. `l0` is the log byte-length BEFORE
/// this append ; `entries` are the `(start_offset, aggregate_name)` of the new
/// lines ; `new_total_len` is the log byte-length AFTER. Must be called AFTER
/// the log bytes are durably written. Self-heals (rebuilds) when the index
/// isn't already complete through `l0`, then appends and advances the marker.
pub fn record_appends(global: &str, l0: u64, entries: &[(u64, String, u64)], new_total_len: u64) {
    let in_sync = std::path::Path::new(&idx_path(global)).exists() && read_marker(global) == l0;
    if !in_sync {
        rebuild(global, l0);
    }
    let mut buf = String::new();
    for (off, name, seq) in entries {
        buf.push_str(&format!("{}\t{}\t{}\n", off, name, seq));
    }
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(idx_path(global))
    {
        let _ = f.write_all(buf.as_bytes());
    }
    // The COMMIT MARKER, written last : everything above is now durable.
    write_marker(global, new_total_len);
}

/// Reader : the byte offsets of `name`'s events — but ONLY when the index is
/// provably complete (`marker == log length`). `None` means "index not usable,
/// full-scan instead" : incomplete after a crash, missing, or malformed. Never
/// returns a partial set that could drop a real match.
pub fn complete_offsets_for(global: &str, name: &str) -> Option<Vec<u64>> {
    if read_marker(global) != log_len(global) {
        return None;
    }
    let text = std::fs::read_to_string(idx_path(global)).ok()?;
    let mut offsets = Vec::new();
    for line in text.lines() {
        // 3-col : <offset>\t<name>\t<sequence>. Name is the 2nd field ; the
        // sequence (3rd) is unused for the name-Eq seek.
        let mut parts = line.splitn(3, '\t');
        let off: u64 = parts.next()?.parse().ok()?;
        if parts.next().unwrap_or("") == name {
            offsets.push(off);
        }
    }
    Some(offsets)
}

/// Reader : byte offsets of every event whose sequence is in `[lo, hi]`
/// (inclusive ; `None` = open on that side), in log order — but ONLY when the
/// index is provably complete (`marker == log length`), else `None` (stream
/// fallback, always correct). The sequence column is ascending (append order ==
/// sequence order), so this binary-searches to the first in-range row and walks
/// forward. Gaps are fine ; a SUPERSET is acceptable (the oracle re-filters).
/// Bounds are already collapsed from Gt/Gte/Lt/Lte to inclusive lo/hi.
pub fn complete_offsets_in_seq_range(
    global: &str,
    lo: Option<u64>,
    hi: Option<u64>,
) -> Option<Vec<u64>> {
    if read_marker(global) != log_len(global) {
        return None;
    }
    let text = std::fs::read_to_string(idx_path(global)).ok()?;
    // (offset, sequence) per line ; lines without a parseable sequence are
    // dropped (they can't match a sequence range). Order is preserved, so the
    // surviving rows stay sequence-ascending.
    let rows: Vec<(u64, u64)> = text
        .lines()
        .filter_map(|line| {
            let mut parts = line.splitn(3, '\t');
            let off: u64 = parts.next()?.parse().ok()?;
            let _name = parts.next()?;
            let seq: u64 = parts.next()?.parse().ok()?;
            Some((off, seq))
        })
        .collect();
    let start = match lo {
        Some(lo) => rows.partition_point(|(_, seq)| *seq < lo),
        None => 0,
    };
    let mut offsets = Vec::new();
    for (off, seq) in &rows[start..] {
        if let Some(hi) = hi {
            if *seq > hi {
                break;
            }
        }
        offsets.push(*off);
    }
    Some(offsets)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp(name: &str) -> String {
        let p = std::env::temp_dir()
            .join(format!("event_log_index_{}_{}/event.log", std::process::id(), name));
        let _ = std::fs::remove_dir_all(p.parent().unwrap());
        let _ = std::fs::create_dir_all(p.parent().unwrap());
        p.to_string_lossy().into_owned()
    }

    // Append two lines through the same offset bookkeeping append_records uses,
    // then assert the index resolves each name to the right offsets AND that
    // seeking to those offsets reads the matching lines back.
    fn write_log_line(global: &str, l0: u64, name: &str, id: &str) -> (u64, String) {
        let line = format!("{{\"event_id\":\"{}\",\"aggregate_name\":\"{}\"}}", id, name);
        let mut f = std::fs::OpenOptions::new().create(true).append(true).open(global).unwrap();
        f.write_all(line.as_bytes()).unwrap();
        f.write_all(b"\n").unwrap();
        (l0, line)
    }

    #[test]
    fn index_resolves_offsets_and_marker_gates_completeness() {
        let g = tmp("basic");
        // line 0 : Order, line 1 : Pizza, line 2 : Order
        let (o0, l0) = write_log_line(&g, 0, "Order", "e0");
        let len0 = l0.len() as u64 + 1;
        let (o1, l1) = write_log_line(&g, len0, "Pizza", "e1");
        let len1 = len0 + l1.len() as u64 + 1;
        let (o2, l2) = write_log_line(&g, len1, "Order", "e2");
        let total = len1 + l2.len() as u64 + 1;
        record_appends(&g, 0, &[(o0, "Order".into(), 1), (o1, "Pizza".into(), 2), (o2, "Order".into(), 3)], total);

        let offs = complete_offsets_for(&g, "Order").expect("index complete");
        assert_eq!(offs, vec![0, len1]);
        assert_eq!(complete_offsets_for(&g, "Pizza").unwrap(), vec![len0]);
    }

    #[test]
    fn incomplete_marker_returns_none_for_full_scan_fallback() {
        let g = tmp("incomplete");
        let (o0, l0) = write_log_line(&g, 0, "Order", "e0");
        // Marker deliberately behind the log (simulating a crash before commit).
        write_marker(&g, 0);
        let _ = (o0, l0);
        assert!(complete_offsets_for(&g, "Order").is_none());
    }

    #[test]
    fn rebuild_heals_a_missing_index_on_next_append() {
        let g = tmp("heal");
        // Two lines exist in the log but the index was never built.
        let (_o0, l0) = write_log_line(&g, 0, "Order", "e0");
        let len0 = l0.len() as u64 + 1;
        let (o1, l1) = write_log_line(&g, len0, "Order", "e1");
        let total = len0 + l1.len() as u64 + 1;
        // record_appends sees no index (marker 0 != l0=len0) and rebuilds [0..len0]
        // before appending the new entry — so BOTH events are indexed.
        record_appends(&g, len0, &[(o1, "Order".into(), 2)], total);
        assert_eq!(complete_offsets_for(&g, "Order").unwrap(), vec![0, len0]);
    }

    #[test]
    fn seq_range_resolves_inclusive_bounds_and_open_ended() {
        let g = tmp("seqrange");
        let (o0, l0) = write_log_line(&g, 0, "Order", "e0");
        let len0 = l0.len() as u64 + 1;
        let (o1, l1) = write_log_line(&g, len0, "Order", "e1");
        let len1 = len0 + l1.len() as u64 + 1;
        let (o2, l2) = write_log_line(&g, len1, "Order", "e2");
        let total = len1 + l2.len() as u64 + 1;
        // sequences 5, 6, 7 at offsets 0, len0, len1.
        record_appends(&g, 0, &[(o0, "Order".into(), 5), (o1, "Order".into(), 6), (o2, "Order".into(), 7)], total);
        // inclusive [6,7]
        assert_eq!(complete_offsets_in_seq_range(&g, Some(6), Some(7)).unwrap(), vec![len0, len1]);
        // open-ended low (..,6]
        assert_eq!(complete_offsets_in_seq_range(&g, None, Some(6)).unwrap(), vec![0, len0]);
        // open-ended high [6,..)
        assert_eq!(complete_offsets_in_seq_range(&g, Some(6), None).unwrap(), vec![len0, len1]);
        // above all -> empty
        assert!(complete_offsets_in_seq_range(&g, Some(8), None).unwrap().is_empty());
    }

    #[test]
    fn seq_range_handles_gaps() {
        let g = tmp("seqgap");
        let (o0, l0) = write_log_line(&g, 0, "Order", "e0");
        let len0 = l0.len() as u64 + 1;
        let (o1, l1) = write_log_line(&g, len0, "Order", "e1");
        let total = len0 + l1.len() as u64 + 1;
        // sequences 10 and 20 (a gap between).
        record_appends(&g, 0, &[(o0, "Order".into(), 10), (o1, "Order".into(), 20)], total);
        assert!(complete_offsets_in_seq_range(&g, Some(11), Some(19)).unwrap().is_empty());
        assert_eq!(complete_offsets_in_seq_range(&g, Some(10), Some(20)).unwrap(), vec![0, len0]);
        assert_eq!(complete_offsets_in_seq_range(&g, Some(15), None).unwrap(), vec![len0]);
    }

    #[test]
    fn seq_range_incomplete_marker_returns_none() {
        let g = tmp("seqincomplete");
        let (o0, l0) = write_log_line(&g, 0, "Order", "e0");
        let _ = (o0, l0);
        write_marker(&g, 0); // marker behind the log
        assert!(complete_offsets_in_seq_range(&g, Some(1), None).is_none());
    }

    #[test]
    fn migration_ignores_legacy_2col_idx_and_rebuilds_idx2() {
        let g = tmp("migrate");
        let lines = [
            "{\"event_id\":\"e0\",\"aggregate_name\":\"Order\",\"sequence\":{\"value\":1}}",
            "{\"event_id\":\"e1\",\"aggregate_name\":\"Pizza\",\"sequence\":{\"value\":2}}",
            "{\"event_id\":\"e2\",\"aggregate_name\":\"Order\",\"sequence\":{\"value\":3}}",
        ];
        let len0 = lines[0].len() as u64 + 1;
        let len1 = len0 + lines[1].len() as u64 + 1;
        let total = len1 + lines[2].len() as u64 + 1;
        std::fs::write(&g, format!("{}\n{}\n{}\n", lines[0], lines[1], lines[2])).unwrap();
        // Pre-seed a STALE legacy 2-col .idx + marker (the pre-migration state).
        std::fs::write(format!("{}.idx", g), "0\tOrder\n").unwrap();
        std::fs::write(format!("{}.idx.len", g), total.to_string()).unwrap();
        // Append e2 : new code finds no .idx2 -> rebuilds [0..len1] in 3-col, adds e2.
        record_appends(&g, len1, &[(len1, "Order".into(), 3)], total);
        // Name seek works for all (rebuild read names from the log).
        assert_eq!(complete_offsets_for(&g, "Order").unwrap(), vec![0, len1]);
        assert_eq!(complete_offsets_for(&g, "Pizza").unwrap(), vec![len0]);
        // Sequence-range seek works (proves the 3rd column was rebuilt from the log).
        assert_eq!(complete_offsets_in_seq_range(&g, Some(2), Some(3)).unwrap(), vec![len0, len1]);
        // The legacy 2-col .idx was never read — still our stale stub.
        assert_eq!(std::fs::read_to_string(format!("{}.idx", g)).unwrap(), "0\tOrder\n");
    }
}
