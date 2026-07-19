# SESSION STATE — 2026-07-19 : validator arc + outbox-as-event-sourcing (restart prompt)

`main` is clean and green (full suite 108/108 test binaries, hecksagon parity
400/400). Everything below is COMMITTED + PUSHED. Two arcs this session : a
validator + kernel bug fix (closed), and the outbox→event-sourcing pivot (in
flight, design locked, foundation shipped).

## ARC 1 — policy-ref-alignment validator + belongs_to-FK fix (CLOSED)
- `b3630d2ca` feat(validator) : `policy_reference_alignment_errors` in
  validator_corpus.rs — a cross-aggregate policy whose triggered command's
  reference is MISNAMED (event carries the entity under another name) would
  silently ride the singleton fallback to an arbitrary record. NARROWED to
  name-mismatch only (Chris) : pure singleton-reliance is out of scope. Fires
  0× on the live corpus ; wired into `validate --corpus`.
- `837d75973` feat(runtime) : the deeper bug it uncovered — a create command's
  `reference_to X` input (a belongs_to FK) was never written to state, so
  belongs_to-on-event emitted an empty FK and downstream policies hit the
  singleton fallback. Fixed in command_dispatch.rs (is_new folds belongs_to
  refs into state). ToolShed's CheckInOnReturn was a live instance — fixed
  (Loan belongs_to Tool/Member) + proven by toolshed_return_cascade_test.

## ARC 2 — outbox is a projection, event sourcing via hecksagon (IN FLIGHT)
Full plan + rationale : `inbox/PLAN-outbox-as-projection-not-aggregate.md`
(read it first). The symptom that started it : ToolShed's served page showed
the framework `OutboundEvent` as a module (the serve attaches every repo
hecksagon → has_effect → the ensure_outbox_substrate injection grafts
OutboundEvent onto every served domain).

### Design — LOCKED (Chris)
- The outbox is NOT a pure Log-fold projection (the Log is DELTA-oriented —
  field:=value + correlation_id, not a stream of emit records — so
  reconstructing emits from deltas is awkward). MODEL A : the outbox stays a
  bluebook AGGREGATE, marked `event_sourced`. Its Record/Claim/MarkDelivered
  history rides the Log ; its `Pending` query IS the read model of undelivered
  deliveries. "Deal with events like everything else", turned on through the
  hecksagon.
- Event sourcing is its OWN hecksagon directive, `event_sourced` (persistence+
  — layered ON persistence, not a peer adapter). `persisted_by("Heki")` is the
  snapshot base ; `event_sourced` adds the Log. heki COMPOSES (it is the
  snapshot layer under ES : "a cached fold, on-read fall-forward to replay").

### Writer verified SAFE (the blocker was stale)
The event-Log writer is gated OFF by default (`HECKS_EVENT_SOURCING`) with a
comment about lossy whole-file RMW. That rationale is STALE : the shards+merge
topology superseded it and is PROVEN lossless — event_merge.rs
`thirty_concurrent_writers_lose_nothing` (1500 events / 30 writers / 0 lost ;
old whole-file repo lost 13/30). Merge wired via the Consolidation Driver
(`storehouse drive` fires `EventSourcing::Consolidation.Consolidate` →
run_consolidate → merge_pass). Eventually-consistent : a shard is visible
within one consolidation tick — right for an outbox.

### Shipped
- `d87d9729a` STEP 1 : the `event_sourced` directive. hecksagon_parser.rs
  (is_binding_line/parse_binding accept the no-paren `FQN.verb` form — Ruby's
  FqnBindingProxy already recorded it, Rust was dropping it = latent drift) ;
  mod.rs `aggregate_is_event_sourced` + record_event_append's gate becomes
  "global env override OR this aggregate carries event_sourced". Parity 400/400.
- `5f9e5674e` STEP 2 slice 1 : OutboundEvent marked `event_sourced` in
  outbound_event.hecksagon (parity now validates the directive on a REAL file)
  + removed from is_infra_mechanism (its delivery_id is stable, so it belongs
  in the Log).

### NEXT SLICES (fresh head, kernel-floor, each a green gated commit)
1. **End-to-end Log-write proof** : a test that an event_sourced outbox
   dispatched Record→Claim lands those deltas in the Log. Needs booting WITH
   the EventSourcing framework chapter (Event aggregate + a data_dir for the
   shard dir). Mirror effect_outbound_record_test's boot + load the
   EventSourcing bluebook. THIS is where step 1's write-toggle gets its
   end-to-end proof.
2. **Host reads the read model** : redirect run_host/mod.rs `pending_deliveries`
   (line ~145) AND mod.rs `drain_outbound_to_quiescence` (~3150) OFF the raw
   `rt.all("OutboundEvent").filter(status==pending)` — they already read the
   aggregate ; with ES on, that IS the folded read model, so this may be a
   no-op / rename, OR route through the `Pending` query. Verify the delivery
   round-trip still works (host_pass_test).
3. **Delete the injection** : remove `ensure_outbox_substrate` (mod.rs ~434) +
   its call ; OutboundEvent is a normal framework aggregate present via the
   corpus realm. WATCH : effect domains served standalone (merge_tree, no
   corpus walk) must still carry OutboundEvent for delivery to record — this is
   the interlocking constraint. Options : runtime-owned merge (unconditional,
   category‑framework, hidden from the served UI via a user_aggregates filter —
   an earlier reverted slice built exactly this : injection‑delete + UI‑filter
   survive model A ; the runtime‑owned MERGE was the transitional part). The
   served page goes clean because the outbox is never grafted onto a user domain.

## Method notes (proven this session)
- Loop is MODEL-bound : batch with fat Bash dispatches (build && test && parity)
  and Explore subagents for recon (a multi-file map = one round-trip).
- Kernel changes : antibody needs `[antibody-exempt: Rust runtime — …]` and
  loc-ratchet needs `[loc-ratchet-override: core_runtime …]` (core_runtime is a
  SHRINK concern ; the ratchet LAGS one commit, reading the pending message).
  Chris ruled this kernel-runtime category exempt ; keep applying + reporting.
- Parity : `cargo build --release -p storehouse-cli --bin storehouse` then
  `ruby -Iruby parity/hecksagon_parity_test.rb` (Ruby lib is `ruby/`, NOT lib/).
