# Time reaches a saga as a command an inbound clock dispatches

**Status:** Proposed. Date: 2026-11-02. Adds no bluebook grammar word; it settles how a deadline is
modelled and names the one missing piece, the inbound clock.

## Context

A process manager cannot say "if the money has not been credited in three days, reverse the debit".
`process_manager.bluebook` has `correlates_by`, `starts_on`, `ends_on`, `resumes`, `transition`,
`dispatch` and `compensates`, and no word about time. The runtime has no scheduler: nothing under
`lib/hecks/runtime`, `ports` or `adapters` dispatches later or on a tick. The only timed logic is the
outbox's `STALLED_AFTER` (`lib/hecks/runtime/outbox.rb`), which is about stuck rows, not deadlines.

Most of a deadline already has a home:

- A command reads the time by declaring `attribute :now, Instant` and `needs :now` (ADR 0081,
  `lib/hecks/bluebook/dsl/need_word.rb`, `docs/implemented/reference/command.md`). The clock port fills
  `now` at dispatch when the caller left it out, and the event records it, so a replay reads the same
  instant. A value the caller supplies wins over the port's.
- A command can refuse on time with a `given` over `now.value`, as
  `qa/stress_domains/lease_clock/bluebook/lease_clock.bluebook` does (`expires_at.value <= now.value`).
- A length of time is a duration attribute: an attribute whose `default:` is whole seconds (ADR 0098),
  and a computed `sets` can add it to `now`.
- A process manager reacts to an event with `transition … do dispatch … end`.

What is missing is the trigger: nothing asks "is anything overdue?" while no one is dispatching.
`docs/future-features.md` (Storehouse item 3, "Drivers") names it: inbound clocks declared in the
hecksagon, out of process, and "hecks's DSL has no inbound-scheduling concept at all".

## Decision

1. **A deadline is data plus an ordinary command.** The aggregate that owns the wait holds the instant it
   falls due. The command that starts the wait declares `needs :now` and writes
   `sets :due_at, to: now + payment_window`, with `payment_window` a duration attribute. A command such
   as `Transfer.Expire` declares `attribute :now, Instant` and `needs :now`, refuses with
   `given("the transfer is overdue") { now.value >= due_at.value }`, and emits `TransferExpired`.
2. **The process manager reacts as it reacts to anything.** `transition Transfer::TransferExpired =>
   "expired", from: "awaiting_credit" do dispatch …, with: { … } end`. An expiry is not a refusal, so
   `compensates` (which runs only when a handler answers the `:refused` trigger) does not fire on it; the
   handler dispatches the undoing commands itself, as the banking `Settlement` manager's `:refused` leg
   dispatches `Transfer::Reverse` (`examples/banking/bluebook/transfers_and_payments.bluebook`). The saga
   learns about time only through an event, so its checkpoint (`registry/saga_persistence.rb`) holds
   nothing a clock could change behind it.
3. **An inbound clock dispatches; it never decides.** Who sends `Expire` is a driving adapter
   (ADR 0103), as Storehouse item 3 describes. It runs out of process, reads candidates through a query,
   and dispatches the command for each without a `now` argument, so the clock port answers it (a `now`
   the adapter supplied would win over the port's). The `given` decides whether the command applies, so
   a clock that fires early, twice or late changes nothing: early is refused, the second firing is
   refused, late expires late.
4. **The deadline belongs to an aggregate, not to the saga.** The domain says what "overdue" means where a
   person can read it and a `given` can test it, instead of in wiring.

## Consequences

- No word is added to the bluebook grammar, and nothing in the Rust parser or kernel changes for the
  deadline itself.
- Existing checks catch some mistakes this shape can make. A handler for `TransferExpired` when no
  command emits it, or a trigger nothing answers, is `deaf_handler` or `deaf_trigger`
  (`model_check/saga_checks.rb`); a state that only expiry reaches, when no handler reaches it, is
  `unreachable_pm_state`. A manager state with no exit is not flagged by any check today.
- `examples/banking` gains a worked expiry. `ScheduledPayment` already has `due_on` and a `Due` query
  "ordered by when they're due", which is the shape an inbound clock would read.
- The inbound clock is the work this ADR leaves. It is a sibling of the relay the outbox (ADR 0053) still
  lacks, Storehouse item 8's "standalone `bin/outbox` relay with a lease/timeout on `claimed`", and the two
  may share a host.

## Alternatives considered

- **A saga word, `awaits "PaymentReceived", within: :payment_window`.** Rejected. It duplicates
  `transition`, which already names the event a state waits for, and adds only a number. A process
  manager has no attributes, so the duration would have no owner (ADR 0098 puts durations on
  aggregates). Sagas are checkpointed and rehydrated, not replayed, so recording `due_at` on entering a
  state would need the saga interpreter to read the clock, which nothing in it does and which ADR 0081
  keeps out of predicates.
- **A scheduler inside the runtime.** Rejected: a dispatching process that also keeps time stalls every
  deadline when it stops, and the deadlines would live in memory no one can query. Storehouse item 3 puts
  the clock out of process for that reason.

## Open questions

- Whether Hecks ships one generic inbound clock (a query to run, a command per row, an interval) or each
  domain writes its own driving adapter, as `lib/hecks/adapters/driving/github_webhook.rb` is written
  today.
- How a clock is declared. A domain names its drivers with `driven_by` (ADR 0103 item 4);
  `Bluebook::Hecksagon::DRIVING_ADAPTERS` is a closed list (`Ruby Cli Json Mcp Web`), and a domain that
  declares any driver refuses the ones it omits, so the first clock adds a member to that list.
  `docs/future-features.md` sketches the spelling `driving on interval | cron | clock`. That word earns its
  place when the first clock is built (ADR 0025).
