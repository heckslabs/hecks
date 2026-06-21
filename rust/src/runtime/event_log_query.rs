//! event_log_query — filtered streaming scan of the append-only Event Log
//!
//! Phase 2 of the where() overhaul. `event_log::load_states` hydrates EVERY
//! line of the (unbounded, growing) JSONL Log into an `AggregateState`, then the
//! runtime filters in memory — so a `Event.Replay("Order")` that wants 50 events
//! pays to build all 10k+. This scans the Log line-by-line (constant-memory
//! `BufReader`) and constructs an `AggregateState` ONLY for lines matching the
//! pushable predicate, so hydrate cost is O(matches), not O(whole-log).
//!
//! Pushed ops : `Eq` on a field — which is exactly the Log's read surface
//! (`Replay` by aggregate_name, `ForAggregate` by aggregate_id, `ByCorrelation`
//! by correlation_id, `AtSequence` by sequence). A line passes when, for every
//! pushed clause, `json_to_value_recursive(field).to_string() == target` — the
//! IDENTICAL conversion `state_from_obj` (the full hydrate) and the
//! `where_matches` oracle use, so a candidate here is a match there. The oracle
//! re-applies EVERY clause on the candidates, so this only narrows — parity by
//! construction. `None` when no clause is pushable, so the caller keeps the
//! cell-backed `all()` path.
//!
//! Byte-offset seeking (read O(matches) instead of stream O(whole-log)) is the
//! Phase-3 concern — a sidecar offset index by aggregate_name maintained on
//! append. This phase removes the O(whole-log) HYDRATE ; Phase 3 removes the
//! O(whole-log) READ.

use super::AggregateState;
use crate::ir::{WhereClause, WhereOp};
use std::collections::HashMap;
use std::io::BufRead;

/// Resolve a where-clause value : `:foo` reads `attrs["foo"]` ; any other token
/// is a literal. Local mirror of the runtime's `resolve_where_value` so the
/// scan resolves identically to the oracle before comparing.
fn resolve(value: &str, attrs: &HashMap<String, String>) -> String {
    if let Some(kwarg) = value.strip_prefix(':') {
        return attrs.get(kwarg).cloned().unwrap_or_default();
    }
    value.to_string()
}

/// The pushable subset of clauses : `(field, resolved_target)` for each `Eq`.
fn pushable_eq(
    wheres: &[WhereClause],
    attrs: &HashMap<String, String>,
) -> Vec<(String, String)> {
    wheres
        .iter()
        .filter_map(|w| match w.op {
            WhereOp::Eq => Some((w.field.clone(), resolve(&w.value, attrs))),
            _ => None,
        })
        .collect()
}

/// Does this parsed line satisfy every pushed Eq clause? Compares each field
/// via the SAME `json_to_value_recursive(..).to_string()` the full hydrate and
/// the oracle use ; a missing field reads as "" (the oracle's `unwrap_or_default`
/// parity).
fn line_matches(
    obj: &serde_json::Map<String, serde_json::Value>,
    pushed: &[(String, String)],
) -> bool {
    pushed.iter().all(|(field, target)| {
        let actual = match obj.get(field) {
            Some(jv) => super::json_to_value_recursive(jv).to_string(),
            None => String::new(),
        };
        actual == *target
    })
}

/// Stream the JSONL Log, returning only the Events matching the pushable Eq
/// clauses, hydrating an `AggregateState` per match. `None` when no clause is
/// pushable (caller falls back to the full read). A missing file yields
/// `Some(empty)` — a pushable query over an absent Log has no matches.
pub fn load_filtered(
    global: &str,
    wheres: &[WhereClause],
    attrs: &HashMap<String, String>,
) -> Option<Vec<AggregateState>> {
    let pushed = pushable_eq(wheres, attrs);
    if pushed.is_empty() {
        return None;
    }
    // Phase 3 fast path : if a clause pins aggregate_name AND the offset index
    // is provably complete, SEEK to that name's events instead of streaming the
    // whole Log. complete_offsets_for returns None when the index can't be
    // trusted (incomplete after a crash, missing) — then we stream (always safe).
    if let Some((_, name)) = pushed
        .iter()
        .find(|(f, _)| f == super::event_log_index::INDEXED_FIELD)
    {
        if let Some(offsets) = super::event_log_index::complete_offsets_for(global, name) {
            return Some(read_by_offsets(global, &offsets, &pushed));
        }
    }
    let file = match std::fs::File::open(global) {
        Ok(f) => f,
        Err(_) => return Some(Vec::new()),
    };
    let reader = std::io::BufReader::new(file);
    let mut out: Vec<AggregateState> = Vec::new();
    for line in reader.lines() {
        let line = match line {
            Ok(l) => l,
            Err(_) => continue,
        };
        if line.trim().is_empty() {
            continue;
        }
        let v: serde_json::Value = match serde_json::from_str(&line) {
            Ok(v) => v,
            Err(_) => continue,
        };
        let obj = match v.as_object() {
            Some(o) => o,
            None => continue,
        };
        if line_matches(obj, &pushed) {
            out.push(super::event_log::state_from_obj(obj));
        }
    }
    Some(out)
}

/// The index fast path's reader : seek to each offset, read that one line, and
/// hydrate the matches. Applies the SAME `line_matches` predicate as the stream
/// scan, so results are identical — just far fewer reads for a selective name.
fn read_by_offsets(
    global: &str,
    offsets: &[u64],
    pushed: &[(String, String)],
) -> Vec<AggregateState> {
    use std::io::{Seek, SeekFrom};
    let file = match std::fs::File::open(global) {
        Ok(f) => f,
        Err(_) => return Vec::new(),
    };
    let mut reader = std::io::BufReader::new(file);
    let mut out = Vec::new();
    for &off in offsets {
        if reader.seek(SeekFrom::Start(off)).is_err() {
            continue;
        }
        let mut line = String::new();
        if reader.read_line(&mut line).is_err() {
            continue;
        }
        let v: serde_json::Value = match serde_json::from_str(line.trim()) {
            Ok(v) => v,
            Err(_) => continue,
        };
        if let Some(obj) = v.as_object() {
            if line_matches(obj, pushed) {
                out.push(super::event_log::state_from_obj(obj));
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn write_log(name: &str, lines: &[&str]) -> String {
        let path = std::env::temp_dir()
            .join(format!("event_log_query_{}_{}/event.log", std::process::id(), name));
        let _ = std::fs::create_dir_all(path.parent().unwrap());
        let mut f = std::fs::File::create(&path).unwrap();
        for l in lines {
            writeln!(f, "{}", l).unwrap();
        }
        path.to_string_lossy().into_owned()
    }

    fn clause(field: &str, op: WhereOp, value: &str) -> WhereClause {
        WhereClause { field: field.into(), op, value: value.into() }
    }

    const LOG: &[&str] = &[
        r#"{"event_id":"e1","aggregate_name":"Order","aggregate_id":"o1"}"#,
        r#"{"event_id":"e2","aggregate_name":"Pizza","aggregate_id":"p1"}"#,
        r#"{"event_id":"e3","aggregate_name":"Order","aggregate_id":"o2"}"#,
    ];

    #[test]
    fn eq_on_aggregate_name_returns_only_matches() {
        let path = write_log("replay", LOG);
        let attrs = HashMap::new();
        let out = load_filtered(&path, &[clause("aggregate_name", WhereOp::Eq, "Order")], &attrs)
            .unwrap();
        let mut ids: Vec<String> = out.iter().map(|s| s.id.clone()).collect();
        ids.sort();
        assert_eq!(ids, vec!["e1".to_string(), "e3".to_string()]);
    }

    #[test]
    fn kwarg_target_resolves_from_attrs() {
        let path = write_log("kwarg", LOG);
        let mut attrs = HashMap::new();
        attrs.insert("aggregate_name".to_string(), "Pizza".to_string());
        let out =
            load_filtered(&path, &[clause("aggregate_name", WhereOp::Eq, ":aggregate_name")], &attrs)
                .unwrap();
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].id, "e2");
    }

    #[test]
    fn no_pushable_clause_returns_none() {
        let path = write_log("nopush", LOG);
        let attrs = HashMap::new();
        assert!(load_filtered(&path, &[clause("sequence", WhereOp::Gt, "1")], &attrs).is_none());
        assert!(load_filtered(&path, &[], &attrs).is_none());
    }

    #[test]
    fn missing_file_with_pushable_clause_is_empty_not_none() {
        let attrs = HashMap::new();
        let out = load_filtered(
            "/tmp/does_not_exist_event_log_query.log",
            &[clause("aggregate_name", WhereOp::Eq, "Order")],
            &attrs,
        );
        assert!(matches!(out, Some(ref v) if v.is_empty()));
    }

    // The Phase-3 index fast path and the Phase-2 stream fallback must return
    // IDENTICAL results. Build the Log through the real append_records (which
    // maintains the index + commit marker), query once via the index, then drop
    // the marker to force the stream path — same ids both ways.
    #[test]
    fn index_fast_path_matches_stream_path() {
        use super::super::event_shard::ShardRecord;
        let dir = std::env::temp_dir().join(format!("elq_idx_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let global = dir.join("event.log").to_string_lossy().into_owned();
        let mk = |id: &str, name: &str| {
            let mut event = serde_json::Map::new();
            event.insert("event_id".into(), serde_json::Value::String(id.into()));
            event.insert("aggregate_name".into(), serde_json::Value::String(name.into()));
            ShardRecord { shard: "s".into(), seq: 0, ts: "t".into(), event_id: id.into(), event }
        };
        super::super::event_log::append_records(
            &global,
            &[mk("e1", "Order"), mk("e2", "Pizza"), mk("e3", "Order")],
        )
        .unwrap();
        let attrs = HashMap::new();
        let wheres = [clause("aggregate_name", WhereOp::Eq, "Order")];

        let mut via_idx: Vec<String> = load_filtered(&global, &wheres, &attrs)
            .unwrap()
            .iter()
            .map(|s| s.id.clone())
            .collect();
        via_idx.sort();
        assert_eq!(via_idx, vec!["e1".to_string(), "e3".to_string()]);

        // Drop the commit marker — the reader must fall back to the stream scan
        // and produce the same ids.
        let _ = std::fs::remove_file(format!("{}.idx.len", global));
        let mut via_stream: Vec<String> = load_filtered(&global, &wheres, &attrs)
            .unwrap()
            .iter()
            .map(|s| s.id.clone())
            .collect();
        via_stream.sort();
        assert_eq!(via_stream, via_idx);
    }
}
