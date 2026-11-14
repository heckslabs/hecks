# A landing's place in the line is its lifecycle

**Status:** Proposed. Date: 2026-11-14. Asked for by the owner after a read of every file of
Switchyard's delivery package. Follows the amendment of
[0195](0195-the-boards-read-model-is-declared-and-its-pages-are-projected-from-declarations.md) (a
rule lives in the bluebook of the aggregate it is about) and applies it to the landing line of
[0205](0205-the-pipeline-is-its-own-project-switchyard-on-a-pinned-hecks.md). Nothing here is built.

## Context

`Delivery::Landing` moves from `requested` straight to a terminal state. Between the two, a landing
joins a line, waits its turn, is taken by a train or takes the front itself, is gated and merges.
All of that is Ruby in `delivery/lib/adapters/git_landing/`, over files in the git directory:

- **The line is ticket files.** A numbered file per landing, a lock for liveness, the file's time
  as a heartbeat, a named pipe for a train's verdict, a counter and a guard lock.
- **Its rules are constants.** Who is next, when a ticket is abandoned, how long a landing waits,
  that a train goes to the front, and how tickets are numbered are decided in `line.rb`,
  `lineup.rb`, `numbering.rb` and `waiting.rb`. The limits are read from a world named "Hecks",
  which Switchyard does not declare, so the Ruby defaults always apply.
- **Nothing can ask about it.** No query says who holds the line, who waits or for how long. The
  board cannot show it; a waiting landing reads the answer on stderr.
- **The gate is not an event.** `Gate.Judge` declares an answer, and a landing calls the adapter
  as a plain method, so a landing's verdict is recorded nowhere.
- **A refusal is one sentence.** A red gate, a conflict, a full line and a red main share one
  `refusal` text, and the submitted job chooses whether to retry by matching words in it.
- **No spec covers it.** The line, the tickets, the train, a stale ticket and a submitted job have
  no example in Switchyard.

## Decision

1. **`Landing` gains the states it passes through.** `waiting` (it joined the line), `holding` (it
   has the front), `gated` (its gate answered green), then the terminal states it has today, with
   `abandoned` added. Each is entered by a command a policy triggers, so each is an event.
2. **One ask becomes a chain.** `Worktrees.Merge` today blocks for the whole wait. It splits into
   `JoinLine` (answers at once), `AwaitTurn` (answers when the landing has the front or a train
   took it), `Gate.Judge` (through the port, to `Landing`) and `Merge`. Each is an ask with one
   answer, which the language says today; the policies between them are the order of a landing.
3. **The line is a query.** `Landing.Line` answers the landings that are `waiting` or `holding`,
   oldest first. The order of the line is the order of that query. The ticket files stay only as
   the adapter's lock between processes, and hold no fact the record does not.
4. **A refusal names its kind.** `Landing` gains a `refusal_kind` (`line_busy`, `main_red`,
   `gate_red`, `conflict`, `stale_base`, `rival`, `unsaved`). What a submitted landing does next is
   a policy on the kind, with its tries as a row, and no code reads a sentence.
5. **An abandoned landing is a stall.** A `StallKind` row times `waiting` and `holding`; the stall
   watch files it and `Landing.Abandon` records it. The adapter stops deciding who has gone away.
6. **The limits are Switchyard's.** Its own world declares how long a landing waits and when one
   is stale, and the delivery package reads no world it does not own.
7. **Specs come first.** Before any of the above, examples pin today's line as it behaves: order,
   a train at the front, a stale ticket, a wait that expires, a submitted landing that retries.

## Alternatives considered

- **A `Line` aggregate beside `Landing`.** It would hold the order as a list and need a writer for
  every join and leave. The order is already the landings' own times, so a query has it for free.
- **Leave the line in the adapter and add only the query.** The query would read ticket files,
  which is a second source of the same fact, and the gate and the refusals would stay undeclared.
- **A process manager for the chain.** It suits a chain that survives a restart. A landing runs in
  one process and is retried whole, so policies say it with less.

## Consequences

- A landing's whole course is in the event log: joined, took the front, gated, merged or refused,
  each with its time. The board's Train and Local main stages read it and stop guessing.
- The chain is slower to write than one blocking call, and `AwaitTurn` still blocks in an adapter.
- Delivery is a vendored package, so each step is a Switchyard release and a new vendoring in Hecks.
- Left open for the owner: whether a train stays a landing that jumps the line or becomes its own
  aggregate that takes the landings ahead of it.
