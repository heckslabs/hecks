module Hecks
  module Runtime
    # THE ONE SHARED CONSTANT between `SagaInterpreter` (the writer) and
    # `Registry::SagaPersistence#rehydrate_sagas!` (the reader) for a
    # scoped, minimal answer to the saga-durability review's item 8 (a
    # durable outbox): a marker that survives exactly the window a crash
    # in `advance_saga`/`unwind` can otherwise hide.
    #
    # THE PROBLEM THIS CLOSES — `checkpoint` persists a saga's new state
    # BEFORE the leg that justifies it (`handler.dispatches`) runs, and
    # deliberately so: the mutex it holds is not reentrant, and a
    # dispatch can re-enter this same interpreter. If the process dies
    # in that window, the store says the transition happened and there
    # is no record that its dispatch(es) never ran — not a refusal (the
    # domain never got asked), not a defect (nothing raised), just
    # silence indistinguishable from a leg that finished cleanly.
    #
    # THE FIX — `checkpoint` now writes this key into the SAME already-
    # durable `memory` blob (no new column, no adapter/schema change:
    # `memory` is already an opaque, adapter-agnostic JSON blob every
    # `save_saga` implementation round-trips verbatim) whenever it
    # checkpoints a state a dispatch cascade hasn't run for YET, and
    # clears it (a second checkpoint, `pending: nil`) once that cascade
    # — success, refusal-compensated, defect-compensated, or ceiling-
    # compensated — has actually run. A crash between those two writes
    # leaves the marker standing; `rehydrate_sagas!` strips it back out
    # of the LIVE instance's own `:memory` (so no dispatch/`given`/
    # fuzzer/doc consumer of a saga's memory ever sees this key — it
    # exists only in the persisted blob) and surfaces it loudly instead.
    #
    # WHAT THIS DELIBERATELY DOES NOT DO — auto-redrive the pending leg.
    # Redelivering a dispatch whose outcome is genuinely unknown is only
    # safe with idempotent delivery (the downstream command recognizing
    # and no-op'ing a duplicate), which hecks's command/event pipeline
    # has no mechanism for today. Blindly re-dispatching without that is
    # how a stalled transfer becomes a DOUBLE-CREDITED one — a strictly
    # worse defect than the stall it would replace. So this is real,
    # durable, crash-surviving VISIBILITY into exactly what a stalled
    # saga was doing when the process died — the missing half of "no
    # reconciliation pass exists". The full pending → claimed →
    # delivered outbox now exists too (`Runtime::Outbox`, ADR 0053) and
    # is COMPLEMENTARY, not a replacement: the outbox row names the
    # EVENT owed to this saga (and redrives it if the saga never got to
    # claim it); this marker names the saga's own LEG mid-flight after
    # the event was delivered. A crash can leave either standing.
    SAGA_PENDING_DISPATCH_KEY = :__hecks_saga_pending_dispatch__
  end
end
