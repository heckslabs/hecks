//! Event sourcing — appending one immutable Event per state delta, and the
//! causation lineage that threads them together.
//!
//! [antibody-exempt: rust/src/runtime/event_sourcing.rs — kernel-floor runtime,
//!  extracted verbatim from runtime/mod.rs (which carries the same marker). The
//!  Log writer is the substrate a bluebook's history is recorded INTO ; it
//!  cannot itself be expressed as one without circularity.]
//!
//! Opt-in PER AGGREGATE via the `event_sourced` hecksagon directive
//! (persistence+ : `persisted_by` is the snapshot base, this adds the Log on
//! top). `HECKS_EVENT_SOURCING` remains a global override ; with neither set
//! nothing is written, the historical default.
//!
//! The Log lives in the FRAMEWORK COLLABORATOR (`framework_substrate.rs`), so a
//! single-bluebook boot carrying the directive writes its Log without the
//! EventSourcing chapter being merged into the user's domain. Before that it
//! silently wrote nothing at all.
//!
//! Writes go to THIS PROCESS's private shard (single-writer, lossless at any
//! size) ; the Consolidation Driver folds shards into the global ordered Log.
//! The shard byte-IO and the merge fold live in `event_shard` / `event_merge` ;
//! this module only wires the realm's paths to them.
//!
//! NAMING : distinct from `crate::event_log`, which is the append-only JSONL
//! STORAGE PRIMITIVE this writes through.

use super::*;

impl Runtime {
    /// True when some attached hecksagon carries `Aggregate.event_sourced`
    /// for this aggregate — the per-aggregate event-sourcing toggle
    /// (persistence+). Bindings store the FQN (`"Ctx::Agg"`) ; the event
    /// carries the bare name (`"Agg"`), so match on the last `::` segment,
    /// as `record_effect_outbound` does. An aggregate carrying the directive
    /// writes its deltas to the Log even with the global HECKS_EVENT_SOURCING
    /// override unset.
    fn aggregate_is_event_sourced(&self, aggregate_type: &str) -> bool {
        self.hecksagons.iter().any(|h| {
            h.bindings.iter().any(|b| {
                b.verb == "event_sourced"
                    && b.aggregate.rsplit("::").next() == Some(aggregate_type)
            })
        })
    }

    /// Event-sourcing Log writer (i-event-sourcing) — append one immutable
    /// `EventSourcing::Event` to the durable Log per delta this command
    /// produced. The out-of-domain sibling of `record_cascade_run` /
    /// `record_effect_outbound` : it records a framework aggregate from
    /// inside the dispatch path via `dispatch_cascade`. The `Event`
    /// aggregate is `identified_by :event_id`, so persisting it yields a
    /// durable, GLOBAL (not per-business-aggregate) append-only Log — the
    /// source of truth. v1 (coexist-then-migrate) : the eager heki current-
    /// state write stays as the Snapshot cache, so reads are unchanged.
    ///
    /// Sequence is the Log's own record count + 1. Append is the sole writer
    /// and never deletes, so count == max sequence, and the persisted Log
    /// self-seeds the sequence across restarts (count() hydrates from disk on
    /// first access) — no runtime counter to keep in sync.
    ///
    /// Recursion guard : skips the EventSourcing domain's own aggregates so
    /// Append never appends. (Belt-and-suspenders — `dispatch_cascade` does
    /// not re-enter this hook ; only the eager dispatch wrapper calls it.)
    pub(super) fn record_event_append(&mut self, result: &CommandResult, command_name: &str, causation_id: &str) {
        // GATE — event sourcing is opt-in PER AGGREGATE via the `event_sourced`
        // hecksagon directive (persistence+). The shards+merge Log writer is
        // now single-writer-safe and proven lossless (thirty_concurrent_
        // writers_lose_nothing : 1500 events / 30 writers / 0 lost), so the old
        // blanket lossiness gate is retired : an aggregate carrying the
        // directive writes its deltas to the Log. HECKS_EVENT_SOURCING stays as
        // a global override (every aggregate) ; neither set -> no Log write
        // (the historical default).
        if result.deltas.is_empty() {
            return;
        }
        let event = match &result.event {
            Some(e) => e.clone(),
            None => return,
        };
        if std::env::var("HECKS_EVENT_SOURCING").is_err()
            && !self.aggregate_is_event_sourced(event.aggregate_type.as_str())
        {
            return;
        }
        // The Event Log lives in the FRAMEWORK COLLABORATOR, not in the user's
        // domain. This used to read
        //
        //     if !self.repositories.contains_key(&es_key) { return; }
        //
        // i.e. "no Log unless the EventSourcing chapter happened to be merged
        // into MY domain" — so a single-bluebook boot carrying the
        // `event_sourced` directive silently wrote nothing at all. There is no
        // such guard now : the collaborator always has the Event aggregate,
        // because the kernel owns it.
        let es_key = repo_key(Some("EventSourcing"), "Event");
        // Infra guard — never event-source the runtime's own machinery.
        // These are MECHANISM, not domain intent : the runtime's delivery
        // bookkeeping (CascadeRun / OutboundEvent / Cascade carry cascades),
        // its process-spawn side-effects (Process), and its liveness
        // supervision (ProcessSentinel / ProcessMacrophage sweep + heal).
        // The bluebook makes them read models OF the Log, so sourcing them
        // would be circular noise — and their ids are process-ephemeral, so
        // fold(Log) can never reconstruct the live store (the verify-projection
        // drift that motivated this list, 2026-06-21).
        if projection_fold::is_infra_mechanism(event.aggregate_type.as_str()) {
            return;
        }
        // Recursion guard — never event-source the EventSourcing aggregates
        // themselves (Append must not append).
        if self.domain.aggregates.iter().any(|a| {
            a.name == event.aggregate_type
                && a.context.as_deref() == Some("EventSourcing")
        }) {
            return;
        }
        // The shard dir : a `shards/` sibling of the Event repo's heki store
            // dir, so the merge daemon's --global (event.heki) and the shards it
            // folds live under one event_sourcing/ root. Memory-backed Event
            // (no disk) has no shard target — skip.
            // The shard dir hangs off the COLLABORATOR's Event repo. The
            // mutable borrow ends with this statement (heki_path returns an
            // owned String), so the per-delta dispatch below can borrow it
            // again — the borrow-shape question step zero exists to answer.
            let store_dir = match self
                .framework_mut()
                .repositories
                .get(&es_key)
                .and_then(|r| r.heki_path())
            {
                Some(d) => d,
                None => return,
            };
            let shard_dir = std::path::Path::new(&store_dir).join("shards");

            // command = verb + inputs (the caller's intent, recorded as fact ;
            // never re-executed by a fold). inputs = the emitted event data JSON.
            let verb = command_name.to_string();
            let inputs = {
                let mut obj = serde_json::Map::new();
                for (k, v) in &event.data {
                    obj.insert(k.clone(), value_to_json(v));
                }
                serde_json::Value::Object(obj).to_string()
            };
            // lineage : one correlation id per originating dispatch ; causation
            // is populated empty this phase (ids ENABLED, facet-queries DEFERRED).
            let correlation_id =
                format!("{}::{}::{}", event.aggregate_type, event.aggregate_id, event.name);
            let recorded_at = storehouse_log::now_iso8601();
            let agg_name = event.aggregate_type.clone();
            let agg_id = event.aggregate_id.clone();
            // One Event per delta, appended to THIS process's private shard.
            // shard + seq + event_id are assigned inside append_to_process_shard
            // (single-writer per process => lossless at any size, no clobber).
            // The merge daemon folds shards into the global event.heki and
            // assigns the authoritative global sequence ; we do NOT compute a
            // global sequence here (the old repo-count+1 is what clobbered).
            let mut last_event_id = String::new();
            for (field, value) in result.deltas.clone() {
                // Reserve this record's shard identity BEFORE dispatch : Event
                // is identified_by :event_id, so the command needs its
                // globally-unique id up front. event_id = "{shard}-{seq}" is
                // the merge's dedup key ; seq is the per-process sequence.
                let (shard, seq) = match event_shard::reserve(&shard_dir) {
                    Some(t) => t,
                    None => return,
                };
                let event_id = format!("{}-{}", shard, seq);
                let mut command_vo = HashMap::new();
                command_vo.insert("verb".to_string(), Value::Str(verb.clone()));
                command_vo.insert("inputs".to_string(), Value::Str(inputs.clone()));
                let mut delta_vo = HashMap::new();
                delta_vo.insert("field".to_string(), Value::Str(field.clone()));
                // FAITHFUL delta : store the field's post-command value as
                // COMPACT JSON, not `Display`. `value.to_string()` renders a
                // Money Map as "{2 fields}" and a ledger List as "[2 items]" —
                // lossy, so the Log could never reconstruct a rich aggregate.
                // value_to_json_string preserves structure ; the fold decodes
                // it back with value_from_json_str. Same serialization
                // discipline as the tool-boundary decode.
                delta_vo.insert("value".to_string(), Value::Str(super::value_to_json_string(&value)));
                let mut sequence_vo = HashMap::new();
                sequence_vo.insert("value".to_string(), Value::Int(seq as i64));
                let mut attrs = HashMap::new();
                last_event_id = event_id.clone();
                attrs.insert("event_id".to_string(), Value::Str(event_id));
                attrs.insert("aggregate_name".to_string(), Value::Str(agg_name.clone()));
                attrs.insert("aggregate_id".to_string(), Value::Str(agg_id.clone()));
                attrs.insert("command".to_string(), Value::Map(command_vo));
                attrs.insert("delta".to_string(), Value::Map(delta_vo));
                attrs.insert("causation_id".to_string(), Value::Str(causation_id.to_string()));
                attrs.insert("correlation_id".to_string(), Value::Str(correlation_id.clone()));
                attrs.insert("actor".to_string(), Value::Str("system".to_string()));
                attrs.insert("sequence".to_string(), Value::Map(sequence_vo));
                attrs.insert("recorded_at".to_string(), Value::Str(recorded_at.clone()));
                // Core dispatch (no pump) — EventSourcing::Event.Append's save
                // routes through the AppendLog adapter to THIS process's shard.
                // The recursion guard above skips the EventSourcing aggregates,
                // so this inner Append never re-enters this hook.
                // Dispatch into the COLLABORATOR, not into self. The user's
                // domain never carried EventSourcing::Event and no longer
                // needs to.
                let _ = command_dispatch::dispatch(
                    self.framework_mut(),
                    "EventSourcing::Event.Append",
                    attrs,
                );
            }
            // Phase-4 causation : remember this command's last recorded event
            // so a cascade off this aggregate can stamp it as its cause.
            if !last_event_id.is_empty() {
                self.note_last_event(&agg_name, &agg_id, &last_event_id);
            }
        }

    /// Phase-4 causation — note the Log event_id just recorded for a domain
    /// aggregate, so a later cascade off it can stamp `causation_id`. Keyed
    /// "<type>::<id>" ; the latest write wins (a command's last delta-event is
    /// the representative cause). In-process, transient.
    pub(super) fn note_last_event(&mut self, agg_type: &str, agg_id: &str, event_id: &str) {
        self.last_event_id_by_agg
            .insert(format!("{}::{}", agg_type, agg_id), event_id.to_string());
    }

    /// Phase-4 causation — the triggering event_id for a cascaded dispatch. A
    /// cascade carries its upstream (type, id) as a hint ; the cause is the
    /// last Log event recorded for that aggregate (the event whose processing
    /// fired this cascade). Empty for a root dispatch (no hint) or an upstream
    /// that recorded no events — both leave causation_id empty, where
    /// CausationTrace stops.
    pub(crate) fn cause_for_cascade(&self, hint: &Option<(String, String)>) -> String {
        hint.as_ref()
            .and_then(|(t, i)| self.last_event_id_by_agg.get(&format!("{}::{}", t, i)).cloned())
            .unwrap_or_default()
    }

    /// Event Log consolidation trigger — fires the merge fold IFF the
    /// dispatched command is the Consolidation maintenance command. Called from
    /// dispatch_inner (so BOTH the manual path AND the driver's dispatch_cascade
    /// reach it). A no-op for every other command. Replaces the run_merge
    /// daemon : `storehouse drive` fires Consolidation.Consolidate on an
    /// interval, and this runs one merge pass.
    pub(super) fn run_consolidate_if(&self, command_name: &str) {
        if command_name == "EventSourcing::Consolidation.Consolidate" {
            self.run_consolidate();
        }
    }

    /// One merge pass : fold this realm's per-process Event shards into the
    /// global ordered Log, writing WHERE the Event repository reads (so a
    /// reader sees the consolidated log — the writer/reader never diverge).
    /// Kernel-floor persistence IO : the shard byte-IO + the fold live in
    /// event_shard / event_merge (siblings of heki.rs) ; this only wires the
    /// realm's paths to them. The checkpoint advances only after a durable
    /// global write, so a failed write retries next pass and a crash mid-pass
    /// replays idempotently (dedup by event_id). No-op when the Event repo is
    /// memory-backed (no shard dir).
        fn run_consolidate(&self) {
        let es_key = repo_key(Some("EventSourcing"), "Event");
        let store_dir = match self.repositories.get(&es_key).and_then(|r| r.heki_path()) {
            Some(d) => d,
            None => return,
        };
        let shard_dir = std::path::Path::new(&store_dir).join("shards");
        // The global Log path — the APPEND-ONLY JSONL file the AppendLog adapter
        // reads (event_log::global_path with the EventSourcing context), so the
        // merge writer and the aggregate reader never diverge. NOT a heki store :
        // heki is for snapshots, the LOG is append-only (event_log.rs).
        let global = event_log::global_path(&store_dir, Some("EventSourcing"));
        let checkpoint = shard_dir.join(".merge.checkpoint.json");
        let shards = match event_merge::discover_shards(&shard_dir) {
            Ok(s) => s,
            Err(_) => return,
        };
        let mut cp = event_merge::load_checkpoint(&checkpoint)
            .unwrap_or_else(|_| event_merge::Checkpoint::new());
        if let Ok(batch) = event_merge::merge_pass(&shards, &mut cp) {
            // Adopt the advanced checkpoint only after a durable global write
            // (empty batch = nothing to write, offsets unchanged — safe to save).
            let write_ok = batch.is_empty()
                || event_merge::write_batch_to_global(&global, &batch).is_ok();
            if write_ok {
                let _ = event_merge::save_checkpoint(&checkpoint, &cp);
                // Reclaim the per-process shards this merge has now FULLY
                // folded whose owning process is DEAD — the GC half of
                // consolidation (every dispatch process leaves an orphan
                // shard ; without this the data root's .../shards grows without
                // bound). Only when the live-process set is TRUSTWORTHY :
                // live_pids() returns None on a failed/empty ps and we
                // reclaim nothing, never risking a live process's open
                // shard. Persist the pruned checkpoint when anything went.
                if let Some(live) = live_pids() {
                    let n = event_merge::reclaim_consumed_shards(
                        &shards,
                        &mut cp,
                        &|pid| live.contains(&pid),
                    );
                    if n > 0 {
                        let _ = event_merge::save_checkpoint(&checkpoint, &cp);
                    }
                }
            }
        }
    }

    /// One-time migration of the global Event Log from compressed whole-file
    /// heki (`event.heki`) to the append-only JSONL substrate (`event.log`).
    /// Reads the heki store, orders records by sequence, writes them as JSONL,
    /// seeds the `.seq` sidecar from the max sequence, and renames the old heki
    /// aside (`.premigration`, reversible). Returns (before, after) counts.
    /// Refuses if `event.log` already exists. Idempotent at the realm level :
    /// run once per realm, before the new append-only writer goes live.
    pub fn migrate_event_log_to_jsonl(&self) -> Result<(usize, usize), String> {
        let es_key = repo_key(Some("EventSourcing"), "Event");
        let store_dir = self
            .repositories
            .get(&es_key)
            .and_then(|r| r.heki_path())
            .ok_or("EventSourcing::Event not loaded (no store dir)")?;
        let old = crate::heki::path_for(&store_dir, "Event", Some("EventSourcing"));
        let new = event_log::global_path(&store_dir, Some("EventSourcing"));
        if std::path::Path::new(&new).exists() {
            return Err(format!("{} already exists — already migrated", new));
        }
        let store = crate::heki::read(&old).map_err(|e| format!("read {}: {}", old, e))?;
        let before = store.len();
        let seq_of = |r: &crate::heki::Record| -> i64 {
            r.get("sequence")
                .and_then(|v| v.as_object())
                .and_then(|m| m.get("value"))
                .and_then(|v| v.as_i64())
                .unwrap_or(0)
        };
        let mut records: Vec<&crate::heki::Record> = store.values().collect();
        records.sort_by_key(|r| seq_of(r));
        if let Some(parent) = std::path::Path::new(&new).parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let mut buf = String::new();
        let mut max_seq = 0i64;
        for r in &records {
            max_seq = max_seq.max(seq_of(r));
            // heki::Record is a HashMap ; serialize it as a JSON object line.
            let obj: serde_json::Map<String, serde_json::Value> =
                r.iter().map(|(k, v)| (k.clone(), v.clone())).collect();
            buf.push_str(&serde_json::Value::Object(obj).to_string());
            buf.push('\n');
        }
        std::fs::write(&new, &buf).map_err(|e| format!("write {}: {}", new, e))?;
        event_log::write_next_seq(&new, (max_seq + 1).max(1) as u64);
        // Reversible backup of the old heki store.
        let _ = std::fs::rename(&old, format!("{}.premigration", old));
        let after = event_log::load_states(&new).len();
        Ok((before, after))
    }

    /// The unconsolidated Log tail : the Event records that live in the shards
    /// but have NOT yet been folded into the global event.heki. The COMPLETE
    /// Log is the consolidated event.heki PLUS this tail — `verify-projection`
    /// needs both to reconstruct a LIVE aggregate, because a continuously-
    /// dispatching aggregate (e.g. the 2s InboxPoller) always has its freshest
    /// event sitting in a shard, ~consolidation-cadence ahead of event.heki.
    ///
    /// READ-ONLY : unlike run_consolidate, this neither writes the global Log
    /// nor saves the advanced checkpoint — it loads a private checkpoint copy,
    /// runs one merge_pass to collect the post-checkpoint records, and discards
    /// the mutated copy. So a verifier observes the tail without perturbing the
    /// live consolidate driver. The returned states carry the Event's fields in
    /// the same nested shape (delta{field,value}, sequence{value}, recorded_at)
    /// the consolidated reader produces, so the fold treats both uniformly.
    pub fn unconsolidated_log_tail(&self) -> Vec<AggregateState> {
        let es_key = repo_key(Some("EventSourcing"), "Event");
        let store_dir = match self.repositories.get(&es_key).and_then(|r| r.heki_path()) {
            Some(d) => d,
            None => return Vec::new(),
        };
        let shard_dir = std::path::Path::new(&store_dir).join("shards");
        let checkpoint = shard_dir.join(".merge.checkpoint.json");
        let shards = match event_merge::discover_shards(&shard_dir) {
            Ok(s) => s,
            Err(_) => return Vec::new(),
        };
        let mut cp = event_merge::load_checkpoint(&checkpoint)
            .unwrap_or_else(|_| event_merge::Checkpoint::new());
        let batch = match event_merge::merge_pass(&shards, &mut cp) {
            Ok(b) => b,
            Err(_) => return Vec::new(),
        };
        // Discard cp : read-only, no save_checkpoint / write_batch_to_global.
        batch
            .iter()
            .map(|rec| {
                let mut st = AggregateState::new("");
                for (k, v) in &rec.event {
                    st.set(k, json_to_value_recursive(v));
                }
                st
            })
            .collect()
    }
}
