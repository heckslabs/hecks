//! event_shard — the append-only, one-JSON-line-per-event shard that backs
//! the out-of-process Event Log (the shards-plus-merge topology, Chris
//! 2026-06-20 ; see inbox/event-log-oop-precondition.md).
//!
//! WHY bespoke, not a per-process heki file : heki is whole-file
//! read-modify-write (see heki::write_raw). A per-process heki shard would
//! be single-writer (no clobber) but still re-serialize the whole file on
//! every append — which destroys byte-offset resume (the merge daemon would
//! have to re-read + decompress the entire shard every tick). A bespoke
//! append-only format gives TRUE offset resume : the merge daemon tails each
//! shard from where it left off. And because each shard has exactly ONE
//! writer (the owning process), there is no cross-process interleave — so the
//! >4KB O_APPEND-atomicity caveat that killed the multi-writer design does
//! not apply here AT ALL ; a record may be any size.
//!
//! Each line is one self-contained JSON `ShardRecord`. The record carries
//! everything the merge needs to impose a global total order WITHOUT a later
//! format break : `shard` (origin), `seq` (per-process monotonic), `ts`
//! (wall-clock). The merge orders by (ts, shard, seq).
//!
//! SLICE 1 (this file) : format + writer + offset-reader, pure + tested.
//! Does NOT touch record_event_append (still gated off). Slice 2 is the
//! merge daemon + the N-process losslessness proof ; slice 3 rewires the
//! writer + flips the gate. Un-gating is the LAST act, never before merge.

use std::fs::OpenOptions;
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::Path;

/// One immutable event in a process shard : the merge ENVELOPE (the total-order
/// key shard/seq/ts plus the dedup key event_id) and the EVENT itself, carried
/// OPAQUELY as the serialized EventSourcing::Event aggregate (its fields as a
/// JSON object). The shard line no longer hand-lists the Event's fields — the
/// AppendLog adapter serializes the Event AggregateState into `event`, so the
/// Event shape has ONE source (the bluebook), not a parallel struct that drifts.
/// The merge orders by (ts, shard, seq) and writes `event` (the true nested
/// shape — command{verb,inputs}, delta{field,value}, sequence{value}, …) to the
/// global Log, so a reader of the global store sees the real Event, not a
/// flattened copy.
#[derive(Debug, Clone, PartialEq)]
pub struct ShardRecord {
    // ── merge envelope : the total-order key is (ts, shard, seq) ; event_id dedups ──
    pub shard: String,
    pub seq: u64,
    pub ts: String,
    pub event_id: String,
    // ── the event : the Event aggregate's fields, serialized (no duplication) ──
    pub event: serde_json::Map<String, serde_json::Value>,
}

/// Serialize one record to its single-line JSON form (no trailing newline ;
/// the writer adds it). JSON escapes any embedded newline in field values,
/// so the one-record-per-line invariant always holds. Built by hand from a
/// serde_json::Map — the crate carries serde_json but not serde-derive, so
/// this mirrors record_event_append's manual-map style.
pub fn serialize_line(rec: &ShardRecord) -> String {
    use serde_json::Value;
    let mut m = serde_json::Map::new();
    m.insert("shard".into(), Value::String(rec.shard.clone()));
    m.insert("seq".into(), Value::Number(rec.seq.into()));
    m.insert("ts".into(), Value::String(rec.ts.clone()));
    m.insert("event_id".into(), Value::String(rec.event_id.clone()));
    m.insert("event".into(), Value::Object(rec.event.clone()));
    Value::Object(m).to_string()
}

/// Parse one line back to a record. Strict : a complete line that fails to
/// parse (bad JSON or a missing field) is a genuine corruption — single-writer
/// never tears a line — so the caller gets an Err rather than a silent drop.
pub fn parse_line(line: &str) -> Result<ShardRecord, String> {
    let v: serde_json::Value =
        serde_json::from_str(line).map_err(|e| format!("shard parse: {}", e))?;
    let s = |k: &str| -> Result<String, String> {
        v.get(k)
            .and_then(|x| x.as_str())
            .map(|x| x.to_string())
            .ok_or_else(|| format!("shard parse: missing/!str field '{}'", k))
    };
    let seq = v.get("seq")
        .and_then(|x| x.as_u64())
        .ok_or_else(|| "shard parse: missing/!u64 field 'seq'".to_string())?;
    let event = v.get("event")
        .and_then(|x| x.as_object())
        .cloned()
        .ok_or_else(|| "shard parse: missing/!object field 'event'".to_string())?;
    Ok(ShardRecord {
        shard: s("shard")?,
        seq,
        ts: s("ts")?,
        event_id: s("event_id")?,
        event,
    })
}

/// A process-private append-only shard. ONE writer per shard (the owning
/// process), so appends never interleave and the file is never rewritten.
pub struct ShardWriter {
    file: std::fs::File,
}

impl ShardWriter {
    /// Open (creating if absent) a shard for append. The path should be
    /// process-private (keyed by shard id) so this is the sole writer.
    pub fn open(path: &Path) -> std::io::Result<Self> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let file = OpenOptions::new().create(true).append(true).open(path)?;
        Ok(Self { file })
    }

    /// Append one record as a single line and flush, so a crash right after
    /// the call cannot lose an acknowledged event.
    pub fn append(&mut self, rec: &ShardRecord) -> std::io::Result<()> {
        let line = serialize_line(rec);
        writeln!(self.file, "{}", line)?;
        self.file.flush()
    }
}

/// Read every COMPLETE record from `path` starting at byte `offset`, and
/// return them with the new offset (the byte position after the last
/// complete line consumed). A partial trailing line — a write in flight — is
/// NOT consumed ; it is left for the next read. `offset` is always on a line
/// boundary (a previous return value or 0), hence always a UTF-8 boundary.
pub fn read_from(path: &Path, offset: u64) -> std::io::Result<(Vec<ShardRecord>, u64)> {
    let mut f = match std::fs::File::open(path) {
        Ok(f) => f,
        // No shard yet : nothing to read, offset unchanged.
        Err(ref e) if e.kind() == std::io::ErrorKind::NotFound => return Ok((Vec::new(), offset)),
        Err(e) => return Err(e),
    };
    f.seek(SeekFrom::Start(offset))?;
    let mut buf = String::new();
    f.read_to_string(&mut buf)?;

    // Consume only up to the last newline ; anything after is a partial
    // line still being written.
    let consumed = match buf.rfind('\n') {
        Some(i) => i + 1,
        None => 0,
    };
    let mut records = Vec::new();
    for line in buf[..consumed].lines() {
        if line.trim().is_empty() {
            continue;
        }
        match parse_line(line) {
            Ok(r) => records.push(r),
            Err(e) => {
                return Err(std::io::Error::new(std::io::ErrorKind::InvalidData, e));
            }
        }
    }
    Ok((records, offset + consumed as u64))
}

// ── Process-private singleton shard (the live write path) ──────────────
// One shard per process, opened once and appended to for the process's
// life — the single-writer property that makes the append lossless at any
// size. Mirrors storehouse_log::FILE_SINK : a process-global OnceLock so
// record_event_append (called per dispatch, &mut self) writes without
// threading a ShardWriter through the Runtime struct.
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};

static PROCESS_SHARD: OnceLock<Option<Mutex<ShardWriter>>> = OnceLock::new();
static SHARD_SEQ: AtomicU64 = AtomicU64::new(0);
static SHARD_ID: OnceLock<String> = OnceLock::new();

/// Stable per-process-BOOT shard id : pid + a boot nonce (nanos since epoch),
/// so a restart that reuses a pid never writes into the prior boot's shard
/// (shard-identity question q2). Computed once.
pub fn process_shard_id() -> &'static str {
    SHARD_ID.get_or_init(|| {
        let pid = std::process::id();
        let nonce = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        format!("p{}-{}", pid, nonce)
    })
}

/// Lazily open (once per process) the private shard sink rooted at `shard_dir`
/// as `<shard-id>.shard`. Returns the sink, or None if it could not be opened
/// (warned once — a failed Log write never crashes the dispatch). The single
/// place the open path lives ; shared by `reserve` + `append_to_process_shard`.
fn open_sink(shard_dir: &Path) -> Option<&'static Mutex<ShardWriter>> {
    PROCESS_SHARD
        .get_or_init(|| {
            let path = shard_dir.join(format!("{}.shard", process_shard_id()));
            match ShardWriter::open(&path) {
                Ok(w) => Some(Mutex::new(w)),
                Err(e) => {
                    eprintln!("[event_shard] cannot open process shard ({}) — events not logged", e);
                    None
                }
            }
        })
        .as_ref()
}

/// Reserve the next (shard_id, seq) for THIS process WITHOUT writing — the
/// AppendLog persistence adapter's first half of a split write. Event.Append is
/// `identified_by :event_id`, so the runtime must mint the globally-unique id
/// BEFORE dispatch (the command needs it to resolve identity + carry it through
/// the invariant), then the adapter's `save` persists the built record. The id
/// is `event_id = "{shard}-{seq}"` — (shard, per-process seq) is unique across
/// shards, exactly the merge's dedup key. Inits the sink under `shard_dir` on
/// first call ; None if it can't open.
pub fn reserve(shard_dir: &Path) -> Option<(String, u64)> {
    open_sink(shard_dir)?;
    let seq = SHARD_SEQ.fetch_add(1, Ordering::SeqCst) + 1;
    Some((process_shard_id().to_string(), seq))
}

/// Append an ALREADY-stamped record (shard/seq/event_id set, e.g. from
/// `reserve`) to this process's sink — no fetch_add, no re-stamp. Returns false
/// if the sink isn't open or the write fails (warned, never panics). The sink
/// must have been opened by a prior `reserve` / `append_to_process_shard`.
pub fn append_record(rec: &ShardRecord) -> bool {
    let sink = match PROCESS_SHARD.get() {
        Some(Some(m)) => m,
        _ => return false,
    };
    match sink.lock() {
        Ok(mut w) => match w.append(rec) {
            Ok(()) => true,
            Err(e) => {
                eprintln!("[event_shard] shard append failed: {}", e);
                false
            }
        },
        Err(_) => false,
    }
}

/// Append one event to THIS process's private shard. The convenience entry that
/// combines `reserve` (mint shard/seq, stamp event_id) with `append_record`
/// (write) ; the AppendLog adapter splits the two halves instead (reserve at
/// dispatch, write at save). Returns the assigned seq, or None if the shard
/// can't be opened/written.
pub fn append_to_process_shard(shard_dir: &Path, mut rec: ShardRecord) -> Option<u64> {
    let (shard, seq) = reserve(shard_dir)?;
    rec.shard = shard.clone();
    rec.seq = seq;
    // event_id is the merge's dedup key, globally unique across shards.
    rec.event_id = format!("{}-{}", shard, seq);
    if append_record(&rec) {
        Some(seq)
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rec(seq: u64, value: &str) -> ShardRecord {
        // The event payload is now opaque (the serialized Event aggregate).
        // Tests carry a `value` field inside it to assert round-trip fidelity.
        let mut event = serde_json::Map::new();
        event.insert("event_id".into(), serde_json::Value::String(format!("evt-{}", seq)));
        event.insert("aggregate_name".into(), serde_json::Value::String("Order".into()));
        event.insert("value".into(), serde_json::Value::String(value.into()));
        ShardRecord {
            shard: "p-42".into(),
            seq,
            ts: "2026-06-20T16:00:00Z".into(),
            event_id: format!("evt-{}", seq),
            event,
        }
    }

    // Read the test payload back out of the opaque event object.
    fn val(r: &ShardRecord) -> &str {
        r.event.get("value").and_then(|v| v.as_str()).unwrap()
    }

    #[test]
    fn round_trips_through_one_line() {
        let r = rec(1, "pending");
        let line = serialize_line(&r);
        assert!(!line.contains('\n'), "a record must encode to exactly one line");
        assert_eq!(parse_line(&line).unwrap(), r);
    }

    #[test]
    fn newline_in_payload_stays_one_line() {
        // A field value with an embedded newline (e.g. Bash output) must not
        // break the one-record-per-line invariant — JSON escapes it.
        let r = rec(2, "line1\nline2\nline3");
        let line = serialize_line(&r);
        assert_eq!(line.matches('\n').count(), 0);
        assert_eq!(val(&parse_line(&line).unwrap()), "line1\nline2\nline3");
    }

    #[test]
    fn large_payload_round_trips() {
        // Single-writer append is safe at ANY size — prove a >4KB record
        // (the size the multi-writer design could not handle) round-trips.
        let big = "x".repeat(8192);
        let r = rec(3, &big);
        let line = serialize_line(&r);
        assert!(line.len() > 8192);
        assert_eq!(val(&parse_line(&line).unwrap()), big);
    }

    #[test]
    fn writer_then_read_from_zero() {
        let dir = std::env::temp_dir().join(format!("event_shard_test_{}", std::process::id()));
        let path = dir.join("a.shard");
        let _ = std::fs::remove_file(&path);
        let mut w = ShardWriter::open(&path).unwrap();
        w.append(&rec(1, "a")).unwrap();
        w.append(&rec(2, "b")).unwrap();
        let (records, off) = read_from(&path, 0).unwrap();
        assert_eq!(records.len(), 2);
        assert_eq!(val(&records[0]), "a");
        assert_eq!(val(&records[1]), "b");
        assert!(off > 0);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn resume_from_offset_reads_only_new_records() {
        let dir = std::env::temp_dir().join(format!("event_shard_resume_{}", std::process::id()));
        let path = dir.join("a.shard");
        let _ = std::fs::remove_file(&path);
        let mut w = ShardWriter::open(&path).unwrap();
        w.append(&rec(1, "a")).unwrap();
        let (first, off1) = read_from(&path, 0).unwrap();
        assert_eq!(first.len(), 1);
        // Append more AFTER the first read ; resuming from off1 sees only those.
        w.append(&rec(2, "b")).unwrap();
        w.append(&rec(3, "c")).unwrap();
        let (second, off2) = read_from(&path, off1).unwrap();
        assert_eq!(second.iter().map(|r| val(r)).collect::<Vec<_>>(), vec!["b", "c"]);
        assert!(off2 > off1);
        // Resuming from the tip yields nothing.
        let (none, off3) = read_from(&path, off2).unwrap();
        assert!(none.is_empty());
        assert_eq!(off3, off2);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn partial_trailing_line_is_not_consumed() {
        // Simulate a write in flight : a line with no terminating newline.
        let dir = std::env::temp_dir().join(format!("event_shard_partial_{}", std::process::id()));
        let path = dir.join("a.shard");
        let _ = std::fs::remove_file(&path);
        std::fs::create_dir_all(&dir).unwrap();
        let complete = serialize_line(&rec(1, "a"));
        let partial = serialize_line(&rec(2, "b")); // no '\n' after this one
        std::fs::write(&path, format!("{}\n{}", complete, partial)).unwrap();
        let (records, off) = read_from(&path, 0).unwrap();
        // Only the complete line is consumed ; the partial waits.
        assert_eq!(records.len(), 1);
        assert_eq!(val(&records[0]), "a");
        assert_eq!(off as usize, complete.len() + 1); // up to and incl the '\n'
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn missing_shard_reads_empty() {
        let path = std::env::temp_dir().join("event_shard_nonexistent_xyz.shard");
        let _ = std::fs::remove_file(&path);
        let (records, off) = read_from(&path, 0).unwrap();
        assert!(records.is_empty());
        assert_eq!(off, 0);
    }
}
