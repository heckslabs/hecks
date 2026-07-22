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

/// The authorization verdict captured at the entry gate (`authorize_entry`),
/// carried to the synchronous Log writer so a recorded SUCCESS is governable —
/// the Log answers "who did this, in what role, under which policy." Captured
/// BEFORE the principal attrs are stripped ; consumed take-once by
/// `record_event_append` for a ROOT dispatch. A cascade carries None and records
/// the honest `system` actor — its originating actor is linked by correlation_id,
/// not re-attributed per hop. `allowed` is always true at record time : a denied
/// command writes no Event (it sits in Governance::Violation instead).
#[derive(Clone, Debug)]
pub struct CapturedAuth {
    pub actor: String,
    pub role: String,
    pub policy_id: String,
    pub allowed: bool,
}

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
    pub(super) fn record_event_append(&mut self, result: &CommandResult, command_name: &str, causation_id: &str, auth: Option<CapturedAuth>) {
        // GATE — event sourcing is opt-in PER AGGREGATE via the `event_sourced`
        // hecksagon directive (persistence+). The shards+merge Log writer is
        // now single-writer-safe and proven lossless (thirty_concurrent_
        // writers_lose_nothing : 1500 events / 30 writers / 0 lost), so the old
        // blanket lossiness gate is retired : an aggregate carrying the
        // directive writes its deltas to the Log. HECKS_EVENT_SOURCING stays as
        // a global override (every aggregate) ; neither set -> no Log write
        // (the historical default).
        // A command with NO deltas may still have EMITTED its declared event, and
        // since 2ddfc2c88 the domain event is a first-class row (empty delta) — so
        // an empty-delta early return would silently DROP that event-row. The log
        // is the source of truth : it stops only when there is neither a state
        // change nor an emitted event to record.
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
            // Per-flow correlation : the id minted at the ROOT of this flow
            // (dispatch_inner), shared by the root command AND every cascade it
            // triggers, so all events of one business flow carry ONE
            // correlation_id (the ByCorrelation facet). Falls back to the
            // per-event form only if a dispatch reached the writer without a flow
            // root having minted one — defensive ; every dispatch_inner root mints.
            let correlation_id = self.current_correlation.clone().unwrap_or_else(|| {
                format!("{}::{}::{}", event.aggregate_type, event.aggregate_id, event.name)
            });
            let recorded_at = storehouse_log::now_iso8601();
            let agg_name = event.aggregate_type.clone();
            let agg_id = event.aggregate_id.clone();
            // Provenance : the runtime build that recorded these events.
            let runtime_version_val = {
                let mut m = HashMap::new();
                m.insert("value".to_string(), Value::Str(env!("CARGO_PKG_VERSION").to_string()));
                Value::Map(m)
            };
            // Provenance : the version of the bluebook that DECLARED this subject
            // aggregate (Aggregate.bluebook_version, stamped at parse from the
            // `Hecks.bluebook "X", version: "…"` header). Read owned now so the
            // &self borrow releases before the row writes. Empty when the header
            // omits a version — the events still record, without a schema stamp.
            let bluebook_version_val = {
                let v = self
                    .domain
                    .aggregates
                    .iter()
                    .find(|a| a.name == agg_name)
                    .and_then(|a| a.bluebook_version.clone())
                    .unwrap_or_default();
                let mut m = HashMap::new();
                m.insert("value".to_string(), Value::Str(v));
                Value::Map(m)
            };
            // Governability : the REAL actor + verdict this command was admitted
            // under — captured at the entry gate before the principal was stripped.
            // A ROOT dispatch carries its principal ; a cascade (None) records the
            // honest `system` actor, its flow linked by correlation_id. allowed is
            // always true here : a denied command never reaches the writer.
            let (actor_str, v_allowed, v_role, v_policy) = match &auth {
                Some(a) => (a.actor.clone(), a.allowed, a.role.clone(), a.policy_id.clone()),
                None => ("system".to_string(), true, String::new(), "system-origin".to_string()),
            };
            let verdict_val = {
                let mut m = HashMap::new();
                m.insert("allowed".to_string(), Value::Str(if v_allowed { "true" } else { "false" }.to_string()));
                m.insert("role".to_string(), Value::Str(v_role));
                m.insert("policy_id".to_string(), Value::Str(v_policy));
                Value::Map(m)
            };

            // EVENT-ROW — one first-class fact per emitted DOMAIN EVENT :
            // event_name + payload (command.inputs), with an EMPTY delta. The
            // trivial fold skips empty-delta rows, so this lineage/governance
            // fact never disturbs state reconstruction (dual-write). The real
            // actor + verdict + per-flow correlation land here in later slices.
            let mut domain_event_id = String::new();
            if let Some((shard, seq)) = event_shard::reserve(&shard_dir) {
                let event_id = format!("{}-{}", shard, seq);
                domain_event_id = event_id.clone();
                let mut command_vo = HashMap::new();
                command_vo.insert("verb".to_string(), Value::Str(verb.clone()));
                command_vo.insert("inputs".to_string(), Value::Str(inputs.clone()));
                let mut event_name_vo = HashMap::new();
                event_name_vo.insert("value".to_string(), Value::Str(event.name.clone()));
                let mut empty_delta = HashMap::new();
                empty_delta.insert("field".to_string(), Value::Str(String::new()));
                empty_delta.insert("value".to_string(), Value::Str(String::new()));
                let mut sequence_vo = HashMap::new();
                sequence_vo.insert("value".to_string(), Value::Int(seq as i64));
                let mut attrs = HashMap::new();
                attrs.insert("event_id".to_string(), Value::Str(event_id));
                attrs.insert("aggregate_name".to_string(), Value::Str(agg_name.clone()));
                attrs.insert("aggregate_id".to_string(), Value::Str(agg_id.clone()));
                attrs.insert("command".to_string(), Value::Map(command_vo));
                attrs.insert("event_name".to_string(), Value::Map(event_name_vo));
                attrs.insert("delta".to_string(), Value::Map(empty_delta));
                attrs.insert("causation_id".to_string(), Value::Str(causation_id.to_string()));
                attrs.insert("correlation_id".to_string(), Value::Str(correlation_id.clone()));
                attrs.insert("actor".to_string(), Value::Str(actor_str.clone()));
                attrs.insert("verdict".to_string(), verdict_val.clone());
                attrs.insert("sequence".to_string(), Value::Map(sequence_vo));
                attrs.insert("recorded_at".to_string(), Value::Str(recorded_at.clone()));
                attrs.insert("runtime_version".to_string(), runtime_version_val.clone());
                attrs.insert("bluebook_version".to_string(), bluebook_version_val.clone());
                // TRUST : chain this entry to the one before it. Stamped LAST, once
                // every other field is in place, because the hash covers the whole
                // entry — anything added afterwards would not be protected by it.
                self.stamp_chain(&mut attrs);
                let _ = command_dispatch::dispatch(
                    self.framework_mut(),
                    "EventSourcing::Event.Append",
                    attrs,
                );
                // COMPLETENESS : the debt recorded at the caller is now paid.
                self.event_rows_written += 1;
            }

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
                attrs.insert("actor".to_string(), Value::Str(actor_str.clone()));
                attrs.insert("verdict".to_string(), verdict_val.clone());
                attrs.insert("sequence".to_string(), Value::Map(sequence_vo));
                attrs.insert("recorded_at".to_string(), Value::Str(recorded_at.clone()));
                attrs.insert("runtime_version".to_string(), runtime_version_val.clone());
                attrs.insert("bluebook_version".to_string(), bluebook_version_val.clone());
                // TRUST : chain this delta entry to the one before it, same as the
                // event-row above — every entry in the shard is on one chain.
                self.stamp_chain(&mut attrs);
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
            // Phase-4 causation : remember the event a cascade off this aggregate
            // should stamp as its cause. PREFER the first-class DOMAIN EVENT row
            // over the last delta row. Both are minted here, and the delta rows are
            // written last — so plain last-write-wins made a cascade's causation_id
            // point at a bookkeeping delta ROW rather than at the event that
            // actually caused it. That answered "what caused this?" with a field
            // mutation, and left the forward ConsequenceTree from a domain event
            // empty (its children hang off the delta row, not off it). Lineage is a
            // chain of EVENTS ; the delta id survives only as the fallback for an
            // aggregate that recorded deltas without emitting one.
            let cause_row =
                if domain_event_id.is_empty() { &last_event_id } else { &domain_event_id };
            if !cause_row.is_empty() {
                self.note_last_event(&agg_name, &agg_id, &cause_row.clone());
            }
            // Snapshots — cache the fold once the Log has grown far enough past
            // the watermark. Reached only for real domain aggregates : the infra
            // and EventSourcing guards return above, so a Capture can never
            // re-enter this writer.
            self.maybe_capture_snapshot();
        }

    /// COMPLETENESS — does this emitted domain event OWE the Log an event-row?
    ///
    /// Called from the dispatch path BEFORE the writer runs, so that a writer
    /// which returns early still leaves the debt visible. It answers the question
    /// the writer's own early-returns cannot be trusted to answer about themselves.
    ///
    /// The LEGITIMATE reasons no row is owed, and only these :
    ///   * the aggregate is not event_sourced (and the global override is off) —
    ///     nothing is logged for it at all ;
    ///   * it is runtime MECHANISM, not domain intent (Cascade / Process / …) ;
    ///   * it is an EventSourcing aggregate — Append must not append ;
    ///   * the Event repo is memory-backed, so there is no shard to write to.
    /// Every OTHER emitted event owes exactly one row. A guard that swallows one
    /// — as the empty-delta return did — now shows up as a gap rather than as
    /// silence.
    pub(crate) fn owes_event_row(&self, aggregate_type: &str) -> bool {
        if std::env::var("HECKS_EVENT_SOURCING").is_err()
            && !self.aggregate_is_event_sourced(aggregate_type)
        {
            return false;
        }
        if projection_fold::is_infra_mechanism(aggregate_type) {
            return false;
        }
        if self
            .domain
            .aggregates
            .iter()
            .any(|a| a.name == aggregate_type && a.context.as_deref() == Some("EventSourcing"))
        {
            return false;
        }
        // No shard target (memory-backed Event) => nothing is written by design.
        let es_key = repo_key(Some("EventSourcing"), "Event");
        self.framework
            .as_ref()
            .and_then(|fw| fw.repositories.get(&es_key))
            .and_then(|r| r.heki_path())
            .is_some()
    }

    /// The emitted domain events the Log does not contain. ALWAYS ZERO on a
    /// healthy runtime — any other number names events that happened and were not
    /// recorded, which is the one failure a source of truth cannot have.
    pub fn missing_event_rows(&self) -> u64 {
        self.event_rows_owed.saturating_sub(self.event_rows_written)
    }

    /// TRUST (Stage 5) — the content hash of one Log entry, over its own fields
    /// AND the previous entry's hash. Chaining is what turns a per-row checksum
    /// into evidence about the SEQUENCE : change one entry and every entry after
    /// it stops re-deriving.
    ///
    /// Canonical by construction : fields are sorted by name and the hash fields
    /// themselves are excluded, so the digest depends on the entry's MEANING and
    /// not on map iteration order. Values go through `value_to_json_string`, the
    /// same faithful serialisation the Log stores — so a Money map contributes its
    /// structure, not "{2 fields}".
    ///
    /// THE DIGEST IS FNV-1a-64, AND THAT IS A DELIBERATE, NAMED LIMIT. It detects
    /// corruption, truncation and reordering — a log that was supposed to be
    /// immutable and quietly is not. It is NOT proof against a deliberate rewrite:
    /// anyone who can edit an entry can recompute the chain after it. Real
    /// tamper-evidence needs a cryptographic digest AND an anchor the rewriter
    /// cannot reach (a signed or externally-witnessed head) — and a crypto digest
    /// alone, with the head still local, would only LOOK stronger. The chain is
    /// the mechanism ; swapping FNV for SHA-256 is one function, once this lean
    /// crate is willing to take the dependency.
    /// One field's contribution to the digest, normalised so the SAME entry hashes
    /// the same whether it is the attrs going INTO Append or the record coming back
    /// OUT of the store. A single-attribute value object round-trips as either the
    /// bare scalar or `{value: scalar}` depending on which side you are on ; without
    /// this every entry would fail to re-derive and the chain would cry wolf on a
    /// log nobody touched.
    /// It ALSO sorts nested map keys. `Value::Map` is a HashMap, so the same
    /// content serialises as `{verb,inputs}` on one entry and `{inputs,verb}` on
    /// the next — hashing that raw would make the digest depend on iteration order
    /// and the chain would report breaks on a log nobody touched. Determinism is
    /// not a nicety here : a verifier that cries wolf is worse than none.
    fn canon_value(v: &Value) -> String {
        match v {
            // A single-attribute value object : unwrap, so the bare scalar and
            // `{value: scalar}` forms agree.
            Value::Map(m) if m.len() == 1 && m.contains_key("value") => {
                Self::canon_value(m.get("value").expect("checked"))
            }
            Value::Map(m) => {
                let mut keys: Vec<&String> = m.keys().collect();
                keys.sort();
                let mut s = String::from("{");
                for k in keys {
                    s.push_str(k);
                    s.push(':');
                    if let Some(inner) = m.get(k) {
                        s.push_str(&Self::canon_value(inner));
                    }
                    s.push(',');
                }
                s.push('}');
                s
            }
            // Lists keep their order — it is content, not incidental.
            Value::List(items) => {
                let mut s = String::from("[");
                for it in items {
                    s.push_str(&Self::canon_value(it));
                    s.push(',');
                }
                s.push(']');
                s
            }
            other => super::value_to_json_string(other),
        }
    }

    /// TRUST : every entry whose hash does not re-derive. Empty means intact.
    /// Grouped per SHARD (the event_id prefix before its last `-`), ordered by
    /// sequence within the shard — the order the single writer appended them.
    pub(crate) fn chain_breaks(&self, agg_name: &str) -> Vec<serde_json::Value> {
        let mut by_shard: HashMap<String, Vec<&AggregateState>> = HashMap::new();
        for ev in self.all(agg_name) {
            let id = match ev.get("event_id") {
                Value::Str(s) => s.clone(),
                Value::Map(m) => m.get("value").map(|v| v.to_string()).unwrap_or_default(),
                _ => continue,
            };
            if let Some((shard, _)) = id.rsplit_once('-') {
                by_shard.entry(shard.to_string()).or_default().push(ev);
            }
        }
        let field_str = |ev: &AggregateState, k: &str| -> String {
            match ev.get(k) {
                Value::Str(s) => s.clone(),
                Value::Map(m) => m.get("value").map(|v| v.to_string()).unwrap_or_default(),
                _ => String::new(),
            }
        };
        let mut shards: Vec<String> = by_shard.keys().cloned().collect();
        shards.sort();
        let mut breaks = Vec::new();
        for shard in shards {
            let mut entries = by_shard.remove(&shard).unwrap_or_default();
            entries.sort_by_key(|e| match e.get("sequence") {
                Value::Int(i) => *i,
                Value::Map(m) => m.get("value").and_then(|v| v.as_int()).unwrap_or(0),
                _ => 0,
            });
            let mut expected_prev = String::new();
            for ev in entries {
                let recorded = field_str(ev, "entry_hash");
                let prev = field_str(ev, "prev_hash");
                let id = field_str(ev, "event_id");
                // LINK : does this entry name the one before it?
                if prev != expected_prev {
                    breaks.push(serde_json::json!({
                        "event_id": id, "shard": shard, "break": "link",
                        "expected_prev": expected_prev, "found_prev": prev,
                    }));
                }
                // CONTENT : does the entry still hash to what it claims?
                let derived = Self::entry_content_hash(&ev.fields, &prev);
                if derived != recorded {
                    breaks.push(serde_json::json!({
                        "event_id": id, "shard": shard, "break": "content",
                        "recorded": recorded, "derived": derived,
                    }));
                }
                expected_prev = recorded;
            }
        }
        breaks
    }

    fn entry_content_hash(attrs: &HashMap<String, Value>, prev_hash: &str) -> String {
        let mut keys: Vec<&String> = attrs
            .keys()
            .filter(|k| k.as_str() != "prev_hash" && k.as_str() != "entry_hash")
            .collect();
        keys.sort();
        let mut buf = String::new();
        for k in keys {
            buf.push_str(k);
            buf.push('=');
            if let Some(v) = attrs.get(k) {
                buf.push_str(&Self::canon_value(v));
            }
            buf.push(';');
        }
        buf.push_str("prev=");
        buf.push_str(prev_hash);

        // FNV-1a-64.
        let mut h: u64 = 0xcbf2_9ce4_8422_2325;
        for b in buf.as_bytes() {
            h ^= *b as u64;
            h = h.wrapping_mul(0x0000_0100_0000_01b3);
        }
        format!("{:016x}", h)
    }

    /// Stamp `prev_hash` + `entry_hash` onto an entry about to be appended, and
    /// advance this process's chain head. The chain is PER SHARD and a shard has
    /// exactly one writer — this process — so the head is simply the last entry
    /// this runtime wrote. Empty prev_hash marks the first entry of a chain, where
    /// a walk starts.
    fn stamp_chain(&mut self, attrs: &mut HashMap<String, Value>) {
        let prev = self.chain_head.clone().unwrap_or_default();
        let hash = Self::entry_content_hash(attrs, &prev);
        attrs.insert("prev_hash".to_string(), Value::Str(prev));
        attrs.insert("entry_hash".to_string(), Value::Str(hash.clone()));
        self.chain_head = Some(hash);
    }

    /// STAGE 4 — THE READ SIDE. Derive every event-sourced aggregate's state
    /// FROM the Log, rather than merely mirroring it into a parallel store.
    ///
    /// This is what makes the Log authoritative rather than a second record kept
    /// alongside the real one. Until now the eager heki current-state write WAS
    /// the read : if it was stale, truncated, or lost, the read was wrong and the
    /// Log — which had the facts — was never consulted. Now the state a caller
    /// reads is the state the Log says it is.
    ///
    /// `load = Snapshot@watermark + fold_forward(tail)` : the projection is read
    /// through `ReadForward`, so it is O(tail) rather than O(whole-log) (that is
    /// what Stage 3's capture bought) and there is ONE fold shared with the query,
    /// never a second that could drift.
    ///
    /// IDEMPOTENT BY CONSTRUCTION — why overlaying is safe. A delta records the
    /// field's FULL post-command value, never an increment, so applying it once or
    /// five times lands on the same value. That is also why this OVERLAYS the
    /// loaded record instead of replacing it : fields the Log has an opinion about
    /// win, and fields it has never seen (defaults an aggregate was born with)
    /// survive untouched.
    ///
    /// It also dissolves the synchronicity window the arc's locked decision names:
    /// a crash between the state save and the Log append can no longer strand a
    /// recorded event, because the next load re-derives from the Log.
    pub fn hydrate_event_sourced_from_log(&mut self) {
        let name = Self::CURRENT_STATE_PROJECTION;
        let mut params: HashMap<String, String> = HashMap::new();
        params.insert("projection_name".to_string(), name.to_string());
        let folded = self.framework_mut().resolve_query("ReadForward", &params);
        let rows = match folded.get("state").and_then(|s| s.as_array()) {
            Some(rows) if !rows.is_empty() => rows.clone(),
            _ => return,
        };

        // Regroup the flat projection rows ("<agg>::<id>::<field>") per instance.
        // rsplit for the FIELD and split-once for the AGG, so an id containing
        // "::" cannot smear the parse.
        let mut per_instance: HashMap<(String, String), Vec<(String, String)>> = HashMap::new();
        for row in &rows {
            let key = match row.get("key").and_then(|k| k.as_str()) {
                Some(k) => k,
                None => continue,
            };
            let value = row.get("value").and_then(|v| v.as_str()).unwrap_or_default();
            let (agg, rest) = match key.split_once("::") {
                Some(p) => p,
                None => continue,
            };
            let (id, field) = match rest.rsplit_once("::") {
                Some(p) => p,
                None => continue,
            };
            if field.is_empty() {
                continue;
            }
            per_instance
                .entry((agg.to_string(), id.to_string()))
                .or_default()
                .push((field.to_string(), value.to_string()));
        }

        for ((agg, id), fields) in per_instance {
            if !self.aggregate_is_event_sourced(&agg) {
                continue;
            }
            let key = match repo_lookup_key(&self.repositories, &agg) {
                Some(k) => k,
                None => continue,
            };
            // Overlay onto what is already loaded, so Log-known fields win and
            // Log-unknown ones (defaults) survive.
            let mut record = self
                .repositories
                .get(&key)
                .and_then(|r| r.find(&id))
                .cloned()
                .unwrap_or_else(|| AggregateState::new(&id));
            for (field, raw) in fields {
                // The Log stores each delta value as COMPACT JSON, so a Money map
                // and a ledger list decode back TYPED — not as the string that
                // rendered them.
                record.set(&field, super::value_from_json_str(&raw));
            }
            if let Some(repo) = self.repositories.get_mut(&key) {
                repo.seed_record(record);
            }
        }
    }

    /// The trivial per-aggregate current-state projection — the one
    /// `Snapshot.ReadForward` serves (Row key "agg::id::field"). Named once here
    /// so the writer's capture and the reader's fold can never disagree about
    /// WHICH projection the snapshot caches.
    pub(crate) const CURRENT_STATE_PROJECTION: &'static str = "current_state";

    /// How far the Log may run past the snapshot before we re-capture.
    ///
    /// A THRESHOLD, not a timer — the bluebook is explicit twice over ("capture
    /// by THRESHOLD (every N events) or ON-DEMAND, not by time"), and it is right
    /// on the merits : a clock re-captures identical state when nothing happened,
    /// and falls behind exactly when it matters (a burst), because read cost
    /// tracks LOG GROWTH, not elapsed time. Tying capture to growth bounds the
    /// fall-forward tail directly. `HECKS_SNAPSHOT_EVERY` overrides it (0 = never
    /// capture), so a deployment can trade write cost against read cost.
    fn snapshot_threshold() -> i64 {
        std::env::var("HECKS_SNAPSHOT_EVERY")
            .ok()
            .and_then(|v| v.trim().parse().ok())
            .unwrap_or(100)
    }

    /// Capture the current-state snapshot IFF the Log has grown `threshold`
    /// events past the last watermark. Runs on the framework COLLABORATOR, where
    /// both Event and Snapshot live.
    ///
    /// The capture IS the read : it materialises exactly what `ReadForward` would
    /// compute right now (cached rows + the folded tail) and stores it at the new
    /// watermark, so a snapshot can never mean something different from the query
    /// that consumes it — there is one fold, not two. Afterwards the tail is
    /// empty, so the next read is O(1) instead of O(log).
    ///
    /// Safe by construction : a snapshot is a CACHE, never the source of truth.
    /// If this never runs, every read simply folds a longer tail. So a failed or
    /// skipped capture costs time, never correctness.
    ///
    /// KNOWN LIMIT : `sequence` is the per-PROCESS shard sequence until the merge
    /// assigns the global order, so a watermark captured in one process is only
    /// meaningful against that process's ordering. `ReadForward` already carries
    /// this property ; consolidating first is what makes it global.
    pub(super) fn maybe_capture_snapshot(&mut self) {
        let threshold = Self::snapshot_threshold();
        if threshold <= 0 {
            return;
        }
        let name = Self::CURRENT_STATE_PROJECTION;
        let fw = self.framework_mut();

        let head = fw
            .all_qualified(Some("EventSourcing"), "Event")
            .iter()
            .map(|e| match e.get("sequence") {
                Value::Int(i) => *i,
                Value::Map(m) => m.get("value").and_then(|v| v.as_int()).unwrap_or(0),
                _ => 0,
            })
            .max()
            .unwrap_or(0);
        let watermark = match fw.find("Snapshot", name).map(|s| s.get("watermark").clone()) {
            Some(Value::Int(i)) => i,
            Some(Value::Map(m)) => m.get("value").and_then(|v| v.as_int()).unwrap_or(0),
            _ => 0,
        };
        if head - watermark < threshold {
            return;
        }

        // The fold is the READ — one implementation, shared.
        let mut params: HashMap<String, String> = HashMap::new();
        params.insert("projection_name".to_string(), name.to_string());
        let folded = fw.resolve_query("ReadForward", &params);
        let rows: Vec<Value> = folded
            .get("state")
            .and_then(|s| s.as_array())
            .map(|arr| {
                arr.iter()
                    .filter_map(|r| {
                        let k = r.get("key")?.as_str()?.to_string();
                        let v = r.get("value")?.as_str().unwrap_or_default().to_string();
                        let mut row = HashMap::new();
                        row.insert("key".to_string(), Value::Str(k));
                        row.insert("value".to_string(), Value::Str(v));
                        Some(Value::Map(row))
                    })
                    .collect()
            })
            .unwrap_or_default();

        let mut watermark_vo = HashMap::new();
        watermark_vo.insert("value".to_string(), Value::Int(head));
        let mut attrs = HashMap::new();
        attrs.insert("projection_name".to_string(), Value::Str(name.to_string()));
        attrs.insert("watermark".to_string(), Value::Map(watermark_vo));
        attrs.insert("state".to_string(), Value::List(rows));
        let _ = command_dispatch::dispatch(fw, "EventSourcing::Snapshot.Capture", attrs);
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

    /// Mint a fresh per-FLOW correlation id at the ROOT of a dispatch. Every
    /// event in one flow — the root command plus every cascade it triggers —
    /// shares this id, so the Log can gather a whole business flow (a transfer
    /// saga) as one unit (the ByCorrelation facet). Process-unique : a monotonic
    /// counter guarantees no two roots collide within a run ; the wall-clock
    /// second prefix keeps the id readable and distinct across runs, and the
    /// root verb tail names WHICH flow it is. wasm-safe clock (i630).
    pub(crate) fn mint_correlation_id(&self, command_name: &str) -> String {
        use std::sync::atomic::{AtomicU64, Ordering};
        static CORRELATION_SEQ: AtomicU64 = AtomicU64::new(0);
        let n = CORRELATION_SEQ.fetch_add(1, Ordering::Relaxed);
        let secs = crate::clock::now_duration().as_secs();
        let verb = command_name.rsplit('.').next().unwrap_or(command_name);
        format!("corr-{:x}-{:x}-{}", secs, n, verb)
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

    /// DERIVABILITY AS A STANDING INVARIANT — the sibling of run_consolidate_if.
    /// Fires when the dispatched command is the Verification trigger (from the
    /// ProjectionVerification Driver, or by hand) ; a no-op for everything else.
    ///
    /// `verify-projection` proved that current state is derivable from the Log —
    /// the claim the whole substrate rests on — but only when an operator ran it.
    /// A property that must hold CONTINUOUSLY has to be measured continuously, so
    /// the verdict becomes queryable domain state (Verification.Drifted) rather
    /// than console output nobody is watching.
    pub(super) fn run_verification_if(&mut self, command_name: &str) {
        if command_name != "EventSourcing::Verification.Verify" {
            return;
        }
        // The SAME gauge `storehouse verify-projection` reports — one
        // implementation, so the standing invariant and the operator's command can
        // never disagree about what derivable means.
        let measured = projection_fold::measure_persistent(self, 2);
        // COMPLETENESS, measured alongside derivability — two DIFFERENT properties,
        // and the fold gauge is structurally blind to this one : a dropped
        // event-row carries an empty delta, contributes nothing to the fold, and
        // leaves fold(Log) == store looking perfect. Non-zero here means events
        // happened that the Log does not contain.
        let missing = self.missing_event_rows();
        let (status, drift, transient, checked, detail) = match measured {
            None => {
                let s = if missing > 0 { "drifted" } else { "empty" };
                (s, 0usize, 0usize, 0usize, String::from("-"))
            }
            Some((persistent, transient, m)) => {
                // EITHER failure condemns the verdict : state that cannot be
                // rederived, OR events that were never recorded.
                let status = if persistent.is_empty() && missing == 0 { "derivable" } else { "drifted" };
                // A handful of triples is enough to act on ; the whole set could be
                // unbounded, and this is domain state, not a dump.
                let mut keys: Vec<String> = persistent
                    .keys()
                    .map(|(a, i, f)| format!("{a}::{i}::{f}"))
                    .collect();
                keys.sort();
                let detail = if keys.is_empty() {
                    String::from("-")
                } else {
                    let shown = keys.len().min(5);
                    let mut d = keys[..shown].join(", ");
                    if keys.len() > shown {
                        d.push_str(&format!(" (+{} more)", keys.len() - shown));
                    }
                    d
                };
                (status, persistent.len(), transient, m.total_fields, detail)
            }
        };
        let mut attrs: HashMap<String, Value> = HashMap::new();
        attrs.insert("verification_id".to_string(), Value::Str("projection".to_string()));
        attrs.insert("status".to_string(), Value::Str(status.to_string()));
        attrs.insert("checked_at".to_string(), Value::Str(crate::clock::now_iso()));
        attrs.insert("drift_fields".to_string(), Value::Str(drift.to_string()));
        attrs.insert("transient".to_string(), Value::Str(transient.to_string()));
        attrs.insert("fields_checked".to_string(), Value::Str(checked.to_string()));
        attrs.insert("missing_rows".to_string(), Value::Str(missing.to_string()));
        attrs.insert("detail".to_string(), Value::Str(detail));
        // Into the COLLABORATOR, where the EventSourcing chapter lives — same as
        // the Append writer. Ungated core dispatch : the recursion guard skips the
        // EventSourcing aggregates, so recording a verdict cannot re-enter this.
        let _ = command_dispatch::dispatch(
            self.framework_mut(),
            "EventSourcing::Verification.Record",
            attrs,
        );
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
