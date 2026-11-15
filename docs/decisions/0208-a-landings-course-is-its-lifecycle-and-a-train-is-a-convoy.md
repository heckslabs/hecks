# A landing's course is its lifecycle, and a train is a convoy

**Status:** Accepted. Date: 2026-11-14. Accepted by the owner (2026-11-14). Revised 2026-11-14,
after delivery 0.1.3 and 0.1.4 landed the compare-and-swap. Asked for by the owner after a read of every file of Switchyard's delivery
package. Follows the amendment of
[0195](0195-the-boards-read-model-is-declared-and-its-pages-are-projected-from-declarations.md) (a
rule lives in the bluebook of the aggregate it is about) and applies it to the landing of
[0205](0205-the-pipeline-is-its-own-project-switchyard-on-a-pinned-hecks.md). Nothing here is built.

## Context

The first draft of this record was written against a landing line: a numbered ticket file per
landing, a wait for the front, a stale window, a train that jumped the queue. Delivery 0.1.3 and
0.1.4 removed most of it. `Landing.finish!` and `Landing.land!` now take no place and wait for no
landing: each moves `main` by one compare-and-swap (`update-ref` with the expected value), and a
finish that finds `main` moved rebases and gates again, up to five times. Only `Landing.train!`
still takes a place in the old line.

What the read found, and the swap left standing:

- **`Landing` still goes from `requested` straight to a terminal state.** A landing now takes
  seconds, not a wait, but its course (gated, swapped, lost the swap and tried again) is still
  recorded nowhere. Five lost tries are five rebases and five gates, and the record shows none.
- **The gate is not an event.** `Gate.Judge` declares an answer, and a landing calls the adapter
  as a plain method, so a landing's verdict, red or green, is recorded nowhere. The gate marker
  can say "green" for a merge commit the gate never judged.
- **A refusal is one sentence.** A red gate, a conflict, a lost swap, a red main and a rival share
  one `refusal` text, and the submitted job decides whether to retry by matching words in it.
- **The train is a landing of a branch named "train".** It takes the front of the old line, lands
  each ready branch behind it and records what it did to them as one sentence on its own record.
  Its line is the one place ticket files, a stale window, a heartbeat and a named pipe remain.
- **The limits are read from a world Switchyard does not declare.** The train's wait and stale
  window come from a world named "Hecks", so the Ruby defaults always apply.
- **The pinned specs cover a line almost no landing uses.** `spec/landing_line_spec.rb` holds the
  line as it behaved before the swap. It is the ground a train's change stands on, and no more.

## Decision

1. **`Landing` gains the course a landing takes.** `gated` (its gate answered green), `swapped`
   is its terminal state today (`landed`), and a lost swap is an event, `SwapLost`, that carries
   the try number and sends the landing back through rebase and gate. Each step is a command a
   policy triggers, so each is in the event log with its time.
2. **The gate answers through its port.** `Gate.Judge` is asked by a policy on the landing's
   rebase, its answer is `JudgementAnswered` or `JudgementRefused`, and the landing records it.
   The gate marker is written by the policy that hears a green answer for the commit the swap
   then moves `main` to, so a merge commit nobody judged is never marked.
3. **A refusal names its kind.** `Landing` gains a `refusal_kind` (`main_red`, `gate_red`,
   `conflict`, `stale_base`, `swap_lost`, `rival`, `unsaved`, `train_busy`). What a submitted
   landing does next is a policy on the kind, with its tries as a row, and no code reads a
   sentence. The five tries of a finish are that row.
4. **A train is its own aggregate, `Convoy`.** A convoy holds the one place a train needs, takes
   the landings that are `submitted` and ready in the order they were submitted and records
   nothing of its own about them: each landing it takes moves through `gated` and its terminal
   state like any other, with the convoy's key on it. `Landing.Train` starts one. The branch named
   "train", the `convoyed` state and the report sentence go.
5. **The line shrinks to one fact.** A convoy runs alone: an invariant on `Convoy` refuses a
   second one while another is `running`, and a `StallKind` row times a convoy that has stopped
   reporting. The ticket files, the heartbeat, the named pipe, the numbering and the stale window
   of the old line are deleted with the last caller. A landing that is `submitted` and ready is
   what `Landing.Ready` answers, so what a train will take is a query, not a directory listing.
6. **The limits are Switchyard's.** Its own world declares the convoy's limit and the tries of a
   finish, and the delivery package reads no world it does not own.
7. **Specs come in this order.** The swap has its own (`landing_swap_spec.rb`). Before the train
   changes, examples pin it as it behaves: what it lands, what it skips and why, and what a
   waiting branch is told. The line specs go with the line.

## Alternatives considered

- **Keep the landing line as the first draft had it.** The swap made the question moot for
  `finish!` and `land!`; a lifecycle of `waiting` and `holding` would model a wait that no longer
  happens.
- **Move the train's order into a `Line` aggregate.** The order of what a convoy takes is the
  order the landings were submitted, which each landing already carries. A query has it for free.
- **A process manager for the chain.** It suits a chain that survives a restart. A landing runs in
  one process and is retried whole, so policies say it with less.
- **Keep a train as a landing of a branch named "train".** It needs no new aggregate. It keeps a
  `Landing` whose branch is no branch, and a per-branch result no query can read. The owner left
  the choice to the author (2026-11-14), who chose the aggregate for those two reasons.

## Consequences

- A landing's whole course is in the event log: gated, swapped or lost and tried again, refused
  with a kind, each with its time. The board's Train and Local main stages read it and stop
  guessing, and a lost swap becomes visible where it is today five silent rebases.
- The gate verdict is a recorded fact, so "green" on a commit can be checked against what was
  judged.
- The train's old line and its files are deleted, which removes the last place the landing
  adapter decides who goes next.
- Delivery is a vendored package, so each step is a Switchyard release and a new vendoring in
  Hecks.
- A convoy that lands a branch another landing took first is told by the swap, not by a ticket.
