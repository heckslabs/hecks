# An aggregate is the transaction boundary, and model_check reports what crosses it

**Status:** Partly built (items 3 and 5: the bulk mode removed, the size warning). Date: 2026-10-27.

## Context

A record changes in one transaction, and reactions to it arrive later. The command
writes its aggregate, its events and its outbox rows together, and the relay then delivers
each policy's reaction (ADR 0053). That is the shape of an aggregate as a consistency
boundary: one instance changes atomically, and everything else is eventually consistent.

Nothing in the tooling said so, and one construct broke it. A bulk run in
`all_or_nothing` mode (ADR 0125, 0129) sent one command to every row of a query inside
one transaction of the target's store, so a single transaction spanned many instances of
an aggregate. The mode had no caller outside the repository's own specs and docs. ADR
0125 gives it no use case beyond completeness, and its Context says "every change goes
through a command, its givens and its events", while the mode made a group of commands
succeed or fail together, which no single command declares. ADR 0138 removes it.

A rule that needs several records to change together is a business invariant. ADR 0081
already says such a rule gets an aggregate that owns it. A transaction across records
hides the missing aggregate.

An aggregate that keeps growing is the usual way the boundary fails the other direction:
one aggregate collects the commands of several concerns and every change to any of them
contends for the same record. `model_check` reports no size at all.

## Decision

1. **The aggregate is the unit of one transaction.** The guides state it: a command
   changes one aggregate instance and the events it emits, and a reaction to those events
   runs after the commit. Another aggregate changes by a policy or a process manager, never
   inside the first command's transaction.
2. **No check reports a transaction across aggregate types, because the language cannot
   write one.** A command's `sets` name its own aggregate's fields, and `delegates_to`
   takes an `"Entity.Command"` target, which is a piece of the same aggregate. A policy
   reaction runs after the commit. So the boundary holds by construction for aggregate
   types, and a `:transaction_spans_aggregates` finding would have nothing to find. If a
   construct that can write two types in one transaction is ever added, it carries the
   check in the same change.
3. **The bulk `all_or_nothing` mode is removed** (ADR 0138). It was the one construct that
   spanned many instances of one aggregate in a transaction, and its mode was an argument of
   the run's request rather than part of the bluebook's IR, so `model_check` had nothing to
   read. A bulk run is now one transaction per row. Built.
4. **A rule that needs records to change together is modelled** as an aggregate that owns
   it (ADR 0081), not requested of a run.
5. **`model_check` reports `:large_aggregate`** for an aggregate whose declared commands,
   entities and lifecycle states together pass a limit. The limit is a setting of the
   check, not a number in the documentation (no counts in docs). The finding is a warning
   and names the commands that set the fewest of the aggregate's own fields, since
   those are the likeliest to belong to another aggregate. Built in
   `ModelCheck::AggregateChecks`; no aggregate in the corpus passes the limit.
6. **A finding can be acknowledged on the declaration.** An aggregate that means what it
   says carries a stated reason, and the finding is not reported. Not built. This
   follows ADR 0121's rule that an allowance belongs on its own declaration and not in a
   list kept apart from it (`ALLOWED_FINDINGS` stays empty).
7. **Specifications, services and factories stay unmapped as words.** The guides say what
   each DDD pattern is in Hecks: a named `given` or precondition is a specification, the
   owning aggregate of ADR 0081 is the domain service for a rule across records, a command
   that creates a record is the factory, and a declared query is the repository's finder.
   No keyword is added; ADR 0025 says a word earns its place by being used.

## Alternatives considered

- **Keep `all_or_nothing` and warn on it.** An earlier draft did, with an advisory on the
  run's record. Rejected: nothing called the mode, so removing it cost less than keeping
  it to discourage it (ADR 0138).
- **Make the findings errors.** A model may mean a multi-record transaction, and the IR
  cannot tell an invariant from a convenience. The same reasoning kept ADR 0121's
  `:orphaned_reference` a warning.
- **A hard limit on aggregate size.** Any number would be arbitrary, and a large
  aggregate is sometimes right. A warning with a tunable limit reports it without
  ruling on it.
- **A `transaction` word that groups commands.** It would make the exception explicit,
  and it would add a language word whose only use is to defeat the rule it comes with.
  Rejected.

## Consequences

- No construct spans more than one aggregate instance in a transaction, so the boundary
  holds in code and not only in the guides.
- The size warning will report existing aggregates in the corpus. They are triaged
  when the check is built, and the limit is set against what the corpus actually does
  before it is documented.
- The Rust kernel is unaffected: these are static checks over the IR, and no behaviour
  at run time changes.
- Open: whether a process manager's compensations are enough to count a multi-aggregate
  write as declared, and whether the acknowledgement belongs on the aggregate or on the
  command.
