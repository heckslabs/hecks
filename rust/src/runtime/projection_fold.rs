//! projection_fold — the trivial per-aggregate projection : fold the Event Log
//! back into current state. This is what makes "state-as-projection" PROVABLE :
//! current state is DERIVABLE from the Log (the source of truth), not just an
//! independently-saved store. `verify-projection` folds the Log and asserts it
//! reconstructs the live store, flipping the Log from "parallel record" to
//! "source of truth."
//!
//! [antibody-exempt: rust/src/runtime/projection_fold.rs — kernel-floor read-
//!  model fold. The CONCEPT is conceived in the EventSourcing bluebook
//!  (Projection.Apply — the honest delta fold ; Event.Replay — the Log
//!  surface) ; this is its hand-written runtime realization until the
//!  projection layer is generated from that chapter. Sibling of the kernel-
//!  floor event_shard / event_merge IO.]
//!
//! The fold is the simplest reducer the delta shape allows : each Event's delta
//! is (field, value) carrying the field's FULL post-command value, so folding =
//! "for each event in sequence order, set field := value." Last write per field
//! wins = current value — the trivial per-aggregate projection the EventSourcing
//! vision names ("current-state is just the trivial per-aggregate projection").
//!
//! Stringified : the Log stores each delta value as a string
//! (record_event_append wrote `value.to_string()`), so reconstruction is on
//! stringified field values ; the equivalence check compares against the store's
//! `.to_string()` form symmetrically. (Type re-hydration is a later refinement,
//! not needed to prove derivability of the value content.)

use super::{AggregateState, Value};
use std::collections::HashMap;

/// Reconstructed field map for one aggregate instance : field -> stringified value.
pub type ReconstructedState = HashMap<String, String>;

/// Fold the global Log's Event records into per-instance reconstructed state,
/// keyed by (aggregate_name, aggregate_id). Pure : groups by instance, orders
/// by sequence, applies field := value (last write wins). Events with no delta
/// field are skipped.
pub fn fold_event_log(
    events: &[&AggregateState],
) -> HashMap<(String, String), ReconstructedState> {
    // (agg_name, agg_id) -> [(sequence, field, value)]
    let mut grouped: HashMap<(String, String), Vec<(i64, String, String)>> = HashMap::new();
    for ev in events {
        let agg_name = ev.get("aggregate_name").as_str().unwrap_or("").to_string();
        let agg_id = ev.get("aggregate_id").as_str().unwrap_or("").to_string();
        let (field, value) = match ev.get("delta") {
            Value::Map(m) => (
                m.get("field").and_then(|v| v.as_str()).unwrap_or("").to_string(),
                m.get("value").and_then(|v| v.as_str()).unwrap_or("").to_string(),
            ),
            _ => continue,
        };
        let seq = match ev.get("sequence") {
            Value::Map(m) => m.get("value").and_then(|v| v.as_int()).unwrap_or(0),
            Value::Int(i) => *i,
            _ => 0,
        };
        if agg_name.is_empty() || field.is_empty() {
            continue;
        }
        grouped
            .entry((agg_name, agg_id))
            .or_default()
            .push((seq, field, value));
    }
    let mut out = HashMap::new();
    for (key, mut rows) in grouped {
        rows.sort_by_key(|(seq, _, _)| *seq);
        let mut state = ReconstructedState::new();
        for (_, field, value) in rows {
            state.insert(field, value); // last write per field wins
        }
        out.insert(key, state);
    }
    out
}

/// The runtime's own machinery — aggregates that are MECHANISM, not domain
/// intent : delivery bookkeeping (CascadeRun / OutboundEvent / Cascade),
/// process-spawn side-effects (Process), and liveness supervision
/// (ProcessSentinel / ProcessMacrophage). One list, two callers : the write
/// path (`record_event_append`) never SOURCES them and the proof
/// (`verify-projection`) never MEASURES them, so the gauge and the Log agree
/// by construction. Their ids are process-ephemeral, so fold(Log) cannot
/// reconstruct the live store — they are read models OF the Log, not intent.
pub fn is_infra_mechanism(aggregate_type: &str) -> bool {
    matches!(
        aggregate_type,
        "CascadeRun"
            | "OutboundEvent"
            | "Cascade"
            | "Process"
            | "ProcessSentinel"
            | "ProcessMacrophage"
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ev(name: &str, id: &str, seq: i64, field: &str, value: &str) -> AggregateState {
        let mut s = AggregateState::new(&format!("{}-{}-{}", name, id, seq));
        s.set("aggregate_name", Value::Str(name.to_string()));
        s.set("aggregate_id", Value::Str(id.to_string()));
        let mut delta = HashMap::new();
        delta.insert("field".to_string(), Value::Str(field.to_string()));
        delta.insert("value".to_string(), Value::Str(value.to_string()));
        s.set("delta", Value::Map(delta));
        let mut sq = HashMap::new();
        sq.insert("value".to_string(), Value::Int(seq));
        s.set("sequence", Value::Map(sq));
        s
    }

    #[test]
    fn fold_orders_by_sequence_and_last_write_wins_per_instance() {
        // Deliberately out of order : the fold must sort by sequence.
        let e1 = ev("Sweeper", "s1", 1, "status", "idle");
        let e3 = ev("Sweeper", "s1", 3, "status", "done");
        let e2 = ev("Sweeper", "s1", 2, "status", "running");
        // A second field on the same instance, and a different instance.
        let e4 = ev("Sweeper", "s1", 2, "ticks", "7");
        let other = ev("Order", "o1", 1, "total", "5");
        let refs = vec![&e3, &e1, &e4, &other, &e2];

        let folded = fold_event_log(&refs);

        let sweeper = folded.get(&("Sweeper".to_string(), "s1".to_string())).unwrap();
        assert_eq!(sweeper.get("status").unwrap(), "done", "seq 3 must win over 1 and 2");
        assert_eq!(sweeper.get("ticks").unwrap(), "7");
        let order = folded.get(&("Order".to_string(), "o1".to_string())).unwrap();
        assert_eq!(order.get("total").unwrap(), "5");
        assert_eq!(folded.len(), 2, "two distinct instances");
    }

    #[test]
    fn events_without_a_delta_field_are_skipped() {
        let mut no_delta = AggregateState::new("x");
        no_delta.set("aggregate_name", Value::Str("Sweeper".into()));
        no_delta.set("aggregate_id", Value::Str("s1".into()));
        let refs = vec![&no_delta];
        assert!(fold_event_log(&refs).is_empty());
    }
}
