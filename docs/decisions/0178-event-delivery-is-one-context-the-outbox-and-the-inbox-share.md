# Event delivery is one context the outbox and the inbox share

**Status:** Proposed. Date: 2026-11-02. Found by the ubiquitous-language survey of the same day;
Tickets finding `ul-extract-event-delivery`. Meets [ADR 0164](0164-hecks-distills-to-a-core-that-no-satellite-is-needed-to-build.md)
where a satellite is drawn around what it absorbs.

## Context

Hecks delivers an event to its consumers in two places, and neither is a bounded context.

The first is the **outbox**, shipped by [ADR 0053](0053-transactional-outbox-for-domain-events-and-effects.md)
as Ruby runtime code. `Runtime::Outbox::Relay` (`lib/hecks/runtime/outbox/relay.rb`) enqueues one
row per (event, consumer) in the aggregate's own transaction, drains them inline and redrives what a
crash left. `Fanout` resolves the consumers, `ConsumerRunner` runs the policy or process manager a
row names, `Redrive` sweeps the pending rows, and `Runnable` is the row itself. Three adapters hold
the rows: `Adapters::Driven::Memory::OutboxRows`, `Sqlite::Outbox` and `Postgres::Outbox`
(`hecks_outbox`). `Runtime::DispatchClaim` keys each saga dispatch so that delivering it twice
changes nothing. None of this is declared in a bluebook; the Ruby runtime is its only description,
and ADR 0053 line 28 says why the Rust kernel has none: "this is Ruby-runtime durability".

The second is the **inbox** QualityControl grew for itself. `EventCursor`, `EventReaction` and
`EventPump` (`lib/hecks/quality_control/quality_control.bluebook`, from the `EventCursor`
aggregate to `PumpOnRequest`) record how far one consumer has read one domain's event log, record
each policy's reaction once per (consumer, event, policy), and run every attached domain's
policies past their cursors. That is at-least-once delivery with idempotent consumption, the same
contract the outbox keeps, written as a satellite's aggregates because the QA loop needed it and
the outbox offered no door a bluebook could reach.

So one idea has two homes, two vocabularies (`delivery_id` and `consumer` on one side, `cursor`
and `reaction` on the other) and one implementation language each. A third consumer of the idea,
the Rust runtime, has neither.

## Decision

1. **Event delivery is a bounded context, `EventDelivery`, declared in a bluebook.** It is a
   satellite in ADR 0164's sense: the core emits events and names consumers; this context carries
   them. The runtime reaches it through a declared capability, as it reaches Governance today.

2. **Its aggregates are the two sides of a delivery.**
   - `Delivery`: one event owed to one consumer. Created when the event commits; its lifecycle is
     `pending`, `delivered`, `failed`, with `Redrive` taking `failed` back to `pending`. This is
     the outbox row, named for what it is.
   - `Consumer`: one policy or process manager as a reader of one domain's events, with the
     position it has read to. This is QualityControl's `EventCursor`, generalised.
   - `Reaction`: what one consumer answered to one delivery, recorded once. This is
     `EventReaction`, and it is where `DispatchClaim`'s key lives: a reaction recorded is a
     dispatch applied.
   - `Pump`: one run that moves every consumer of a set of domains forward. This is `EventPump`.

3. **The Ruby runtime becomes the context's adapter, not its model.** `Relay`, `Fanout`,
   `ConsumerRunner`, `Redrive` and the three row stores stay as the driven adapter the
   `EventDelivery` hecksagon binds. Their behaviour is unchanged; what changes is that a bluebook
   now says what they promise.

4. **QualityControl drops its three aggregates and attaches `EventDelivery`.** Its `PumpOnRequest`
   policy dispatches `Pump.run!`. The `qa_event_pump*` CLI under `lib/hecks/quality_control/cli/`
   moves with it.

5. **The vocabulary is settled with the move.** A row is a delivery, a reader is a consumer, a
   reader's position is a cursor, and what a reader answered is a reaction. `delivery_id` stays as
   the identity of a `Delivery`.

## Consequences

- One contract, written once, that the differential specs can hold Ruby and Rust to. Today only
  Ruby has it, and only its specs say what it is.
- QualityControl loses three aggregates and the Hecks context gains a satellite with four, which
  is the direction ADR 0164 wants: the satellite depends on the core, never the reverse.
- A domain outside Hecks can declare `attaches "EventDelivery"` and get a durable outbox without
  the Ruby runtime, once an implementation binds the adapter.
- The era machinery is unaffected: deliveries are tooling rows, and the context declares
  `disposable_ledger true` (or whatever [ADR 0179](0179-ledger-names-the-seal-chain-only.md) renames
  it to) in its world.

## Alternatives considered

- **Leave the outbox in Ruby and have QualityControl call it.** Rejected: a bluebook cannot reach
  `Runtime::Outbox` without a capability, and declaring the capability is most of this ADR.
- **Fold the three QC aggregates into the Hecks context's `deliver` module.** Rejected: ADR 0163
  makes `deliver` the push train, and delivery of events is a different thing with the same word.

## Open questions

- **Does Rust need an outbox before ADR 0164's corpus milestone?** The corpus checks the IR, not
  delivery, so `hecks-rust` can pass it without one. But the milestone also retires Ruby as the
  oracle, and from then a Ruby-only outbox is a Ruby-only guarantee. Proposed: the `EventDelivery`
  bluebook lands first, so the Rust adapter has a contract to meet when it is written.
- Whether `Pump` is an aggregate or a command on `Consumer` (`Consumer.advance!` over a set).
  QualityControl made it an aggregate so a run has an identity to report on; this ADR keeps that
  until the move shows otherwise.
