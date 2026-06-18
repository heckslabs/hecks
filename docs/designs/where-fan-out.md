# Locked API : where-scoped fan-out (the primitive already exists)

> Review artifact — becomes the `runtime-cross-aggregate-where` card contract.

## Finding that shrank the build

The fan-out primitive is ALREADY built (i221-A) : `DispatchSpec.for_each:
ForEachSpec` runs a named query, enumerates matches via `sweep_records`,
and dispatches one cascade per record ; `from_iter(:field)` threads each
record's fields into the dispatched command. And the query executor
ALREADY binds input-valued wheres : `where worker: :worker` resolves
`:worker` from passed attrs (`resolve_where_value` → `attrs["worker"]`).

**The entire capability gap is one line.** `sweep_records` runs the query
with `let attrs = HashMap::new()` — EMPTY. So it cannot filter by the
event (“leases where worker == {event.worker}”). Fix : thread
event-derived inputs into the query.

Two true gaps remain, both small :

1. **`sweep_records` is parameterless.** Give `ForEachSpec` a `with:`
   (query inputs, ValueSpecs resolved against the event), thread them
   into `resolve_query_qualified`. Route-independent ; the keystone.
2. **`for_each` is PM-only.** The consumers (reclaim, volunteer_pull) are
   *stateless* driven adapters, not stateful PM sagas. Add `for_each` to
   the driven-adapter path (Route B), reusing `sweep_records` +
   `evaluate_value_spec` (both are `self.` Runtime methods, visible to the
   `driven_adapter_resolver` child module — reuse, not duplication).

## Bluebook surface (locked)

```ruby
# the predicate's home is a first-class query (where already lives there)
query "HeldByWorker" do
  attribute :worker, Worker
  where worker: :worker
end

# the driven adapter fans out, one dispatch per match
driven on "Conductor::Worker.WorkerDied" do |event|
  for_each "Conductor::Lease.HeldByWorker", with: { worker: "{worker}" } do |lease|
    dispatch "Conductor::Lease.Reclaim", id: "{worktree_path}"
  end
end
```

- `for_each "Ctx::Agg.query", with: { input: "{event_field}" } do |bind| <dispatch>+ end`
- `with:` inputs interpolated against the EVENT → query attrs → input-bound
  `where` filters.
- inner dispatch attrs interpolate `{record_field}` (record-first) then
  `{event_field}`.
- all-match fan-out ; empty match → no-op (reactive, never a refuse).
- scan is immutable + pre-borrow (reuses `sweep_records`).

## Build order (parity-gated)

1. **Keystone** — `ForEachSpec.query_inputs: Vec<(String, ValueSpec)>` ;
   `sweep_records(spec, attrs)` threads them into the query. Parse `with:`
   on `for_each` (both targets). Prove via the EXISTING PM path + a
   fixture (parameterized sweep, byte-identical). dump.rs / goldens.
2. **Route B** — `DrivenHandler.for_each: Vec<ForEachBlock>` ; parse in
   `parse_driven_handler` (both targets) ; execute in
   `resolve_driven_adapters` (call `rt.sweep_records` + interpolate
   record-first). Fixture proving one event → N dispatches over a
   predicate, byte-identical.
3. **Wire SEAM 3** — needs Lease→Worker linkage (references-not-ids /
   belongs_to-on-event). If absent, that is a SEPARATE data-model gap ;
   the capability ships + is proven by fixture regardless. Be honest
   about the seam vs the capability.

## Open

- Lease may not store `worker` today (volunteer_pull notes the worker_ref
  is a dead FK kwarg). SEAM 3 wiring depends on that linkage existing ;
  the where-fan-out CAPABILITY does not.
