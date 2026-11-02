# Whether Hecks needs a use case above one command

**Status:** Open. Date: 2026-11-02. A question written down for discussion; it proposes no grammar.

## Context

Alistair Cockburn's use case names a goal a person has, at the level of "transfer money" or "publish an
article": a primary actor, a main success scenario of several steps, and extensions for each way a step
can fail. Hecks describes behaviour one command at a time, and has several pieces that each carry part of
that shape:

- **`goal`** on a command (`command.bluebook`) is documentation (ADR 0025): projections print it, and
  no check or runtime effect reads it.
- **`role`** on a command names who may call it, and means Governance's access control (ADR 0131 allows
  several).
- **`given`** and a port operation's `refuses` are the ways one command can fail.
- **`process_manager`** strings commands together across aggregates, with `compensates` for the legs to
  undo.
- **`.examples`** (ADR 0131) are Given/When/Then scenarios with a `Background:` of people and roles,
  compiled to `.behaviors` and checked against the chapter's names.

None of these says "this is one goal a person has, and these steps reach it". ADR 0138 removed the one
construct that grouped commands, the all-or-nothing bulk mode, because the aggregate is the transaction
(ADR 0137). Whatever a use case is in Hecks, it cannot be a transaction.

## The question

What would a user-goal use case say that none of the pieces above says, and is that worth a word?

ADR 0025 sets the test: one idea, one spelling, and a word earns its place by a check or a runtime effect
plus a corpus use. A use case passes only if it can answer three things:

1. **What it replaces.** If it is a second way to write a process manager or an example, it fails "one
   spelling".
2. **What it checks.** The obvious check, "every refusal a step can meet is handled by an extension", is
   circular: almost every command has `given`s, so every step would warn until someone writes an extension
   whose only effect is to silence the warning.
3. **Where it lives.** A bluebook construct means rows in the language bluebook and the Rust parser table;
   a separate file type adds to the file kinds a newcomer already meets.

## Directions, each with its cost

- **(a) Nothing new.** A use case is read, not declared: the narrate projection renders a process manager
  and the examples that drive it as a use case. Costs nothing in grammar; says nothing a check can hold.
- **(b) Examples name their goal.** An `.examples` file says which user goal it exercises and which actor
  pursues it, and the steps it walks are checked against the declared commands and the refusals they can
  meet. Reuses ADR 0131's file and its compiler; the check is real (a step that names no command, a
  "refused because" that no `given` says). It checks the examples someone wrote and asks for none, so it
  does not warn on every `given`.
- **(c) A bluebook construct.** `use_case` with `actor`, steps and extensions. The most Cockburn-like,
  the most ceremony, and the hardest to separate from `process_manager`.

(b) looks like the smallest step that a check would hold, but this ADR does not decide it.

## Open questions

- Is `actor` the same idea as `role`? `role` means access control today, and an actor in Cockburn's sense
  is whoever has the goal, who may not be the one calling each command.
- Goal levels: only the user goal, or also the summary level above it?
- Which corpus case would test it first. Miette's reflection (a session ends, a perception asks the
  thinker, the answer is recorded or refused) is a candidate with real extensions.
- Who decides: this is a question about what Hecks is for, and belongs to the owner.
