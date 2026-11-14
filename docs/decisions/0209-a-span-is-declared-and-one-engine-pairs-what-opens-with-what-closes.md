# A span is declared, and one engine pairs what opens with what closes

**Status:** Proposed. Date: 2026-11-14. Asked for by the owner after a read of every file of the
pipeline board. Carries out the last bullet of point 8 in the amendment of
[0195](0195-the-boards-read-model-is-declared-and-its-pages-are-projected-from-declarations.md).
Nothing here is built.

## Context

Three bluebooks declare the same idea as rows, and three bodies of Ruby interpret them:

- `StallKind` (`stall_watch.bluebook`): an opening event, closing events, the minutes allowed.
- `HealthCheck` (`pipeline_board.bluebook`): opening and closing events, a join, a bound.
- `CycleStage` (`pipeline_board.bluebook`): opening and closing events per stage, and how a
  closing event belongs to an item.

Each engine pairs an opening event with the first closing event of the same key and measures the
time between. They differ in what they call the key, in how they compare it and in what they do
with an opening nothing closed. The words that tell them apart (`unanswered`, `over`, `carried`,
`after`) are defined in comments and matched in Ruby, with a silent fallback for an unknown word.

Hecks cannot say this in a declaration today:

- A `read_model` reads stored rows of one bluebook when it is asked. It hears no event and
  cannot name an aggregate of another bluebook.
- A reduction (`median`, `percentile`) reads a stored number, and a rule has no subtraction, so
  a duration is never a field.
- The event log (`events.jsonl`) is the only place several contexts' events meet. It holds names,
  ids and seven link keys, no payload, and its plain files reach back some hours.

## Decision

1. **A `span` is a declaration.** It names what `opens` it, what `closes` it, what `joins` the two
   and, where it has one, the bound it must close `within`. The events may be of any attached
   bluebook, as a policy's are.

   ```ruby
   span "Verification" do
     opens  "Hecks::Integration.MainVerificationStarted"
     closes "Hecks::Integration.MainVerified", "Hecks::Integration.MainVerificationFailed"
     joins  :id
     within :verify_bound_minutes
   end
   ```

2. **A span is kept as rows.** The runtime hears the events and keeps one row for each opening:
   its key, when it opened, when it closed, what closed it and its seconds. It is fed like a
   policy is, so it needs no reader of the log and no payload the log lacks.
3. **A span answers queries and read models.** `Verification.Open`, `Verification.Over` (open or
   closed past its bound) and a read model that reduces its `seconds` (`median`, `percentile`,
   grouped by the span's name) are declared with the words queries and read models have today.
4. **The joins are a closed list.** `:id` (the same aggregate), a link key (`:landed`, `:work`),
   or a pair of link keys when the opener and the closer name the commit differently. A join the
   list does not hold is refused at boot, where today an unknown word falls back.
5. **A stage is a span that opens where the last one closed.** `stages` declares an ordered list
   of spans for one item; the board's cycle is that list, and its statistics are a read model.
6. **The three row tables go.** `StallKind`, `HealthCheck` and `CycleStage` become spans, and
   their engines are deleted. What a stall does beyond being found (it files a Work item) stays a
   policy on the span's `Over`.
7. **Ruby first, then Rust.** The construct lands in the Ruby runtime with its conformance cases,
   and the Rust kernel follows before it is used outside tooling, as the parity rule asks.

## Alternatives considered

- **One shared Ruby engine behind a typed query.** It ends the triplication and adds no word. It
  leaves the pairing in an adapter, read from a log with no payload and a short reach, and the
  board's day-long window would still be more than it can see.
- **Policies that stamp times on an aggregate.** Each stage needs two policies and two attributes,
  and the duration still cannot be computed in a rule. It is what `Pipeline::Passage` began.
- **Widen the event log.** Payloads in the log would let the present readers work. The log is a
  trace, kept short on purpose, and making it a store of record undoes that.

## Consequences

- One word says what three tables and three engines say, and model_check can hold a span to the
  lifecycle state it times, as it holds a `StallKind` row today.
- A span's rows need a store that outlives a process, so the tooling domains that declare spans
  keep them, as they keep `AgentRun` and `Landing`.
- History starts when the span is first heard. What happened before is not rebuilt from the log.
- Left open for the owner: the word (`span`, `interval`, `wait`), and whether `stages` is its
  own construct or a list on a read model.
