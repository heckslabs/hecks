# An aggregate is the transaction boundary, and model_check reports what crosses it

**Status:** Proposed. Not built. Date: 2026-10-27.

## Context

A record changes in one transaction, and reactions to it arrive later. The command
writes its aggregate, its events and its outbox rows together, and the relay then delivers
each policy's reaction (ADR 0053). That is the shape of an aggregate as a consistency
boundary: one instance changes atomically, and everything else is eventually consistent.

Nothing in the tooling says so, and one construct breaks it. A bulk run in
`all_or_nothing` mode (ADR 0125, 0129) sends one command to every row of a query inside
one transaction of the target's store, so a single transaction spans many instances of an
aggregate. The mode has no caller outside the repository's own specs and docs. ADR 0125
gives it no use case beyond completeness, and its Context says "every change goes through
a command, its givens and its events", while the mode makes a group of commands succeed
or fail together, which no single command declares.

A rule that needs several records to change together is a business invariant. ADR 0081
already says such a rule gets an aggregate that owns it. `model_check` knows nothing of
this, so a model can lean on a multi-record transaction without the tooling ever asking
whether an aggregate is missing.

An aggregate that keeps growing is the usual way the boundary fails the other direction:
one aggregate collects the commands of several concerns and every change to any of them
contends for the same record. `model_check` reports no size at all.

## Decision

1. **The aggregate is the unit of one transaction.** The guides state it: a command
   changes one aggregate instance and the events it emits, and a reaction to those events
   runs after the commit. Another aggregate changes by a policy or a process manager, never
   inside the first command's transaction.
2. **`model_check` reports `:transaction_spans_aggregates`** for a construct whose one
   transaction writes more than one aggregate type, unless the writes are declared a
   process manager or a saga (which carry their own compensations). The severity is a
   warning, because a model may mean it, and the message names the owning aggregate the
   rule probably needs (ADR 0081). The check reads the IR for the constructs that can do
   it; whether any besides a bulk run can do it today is verified when the check is built,
   and a check with nothing to find is reported as such rather than shipped silent.
3. **`model_check` reports `:bulk_all_or_nothing`** for a bulk run, request or declared
   use, that asks for `all_or_nothing`, as a warning with the message "a rule that needs
   all-or-nothing across records probably needs an owning aggregate". The run still works.
   The mode stays, as an exception for operator sweeps and migrations, and
   `best_effort` stays the default.
4. **ADR 0125 item 4 is amended**, not reversed. The mode's reason is stated: it exists
   so an operator can apply one command to a set of rows without partial results, not so
   a domain rule can span records. ADR 0129 item 5 stands unchanged: the compiled path
   keeps the mode atomic.
5. **`model_check` reports `:large_aggregate`** for an aggregate whose declared commands,
   entities and lifecycle states together pass a limit. The limit is a setting of the
   check, not a number in the documentation (no counts in docs). The finding is a warning
   and names the commands that touch the fewest of the aggregate's attributes, since
   those are the likeliest to belong to another aggregate.
6. **A finding can be acknowledged on the declaration.** An aggregate or bulk request that
   means what it says carries a stated reason, and the finding is not reported. This
   follows ADR 0121's rule that an allowance belongs on its own declaration and not in a
   list kept apart from it (`ALLOWED_FINDINGS` stays empty).
7. **Specifications, services and factories stay unmapped as words.** The guides say what
   each DDD pattern is in Hecks: a named `given` or precondition is a specification, the
   owning aggregate of ADR 0081 is the domain service for a rule across records, a command
   that creates a record is the factory, and a declared query is the repository's finder.
   No keyword is added; ADR 0025 says a word earns its place by being used.

## Alternatives considered

- **Remove `all_or_nothing`.** It is the purest answer and the only one that makes the
  boundary hold in code. It is a breaking change that touches the specs, ADR 0129 and
  the Rust parity work, and nothing in the corpus calls it. Not done: the warning shows
  whether anyone minds before the removal is paid for.
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

- Authors learn where their model leans on a transaction that spans records, and the
  message points at the missing aggregate instead of the symptom.
- `all_or_nothing` stays available and becomes visibly an exception.
- The size warning will report existing aggregates in the corpus. They are triaged
  when the check is built, and the limit is set against what the corpus actually does
  before it is documented.
- The Rust kernel is unaffected: these are static checks over the IR, and no behaviour
  at run time changes.
- Open: whether a process manager's compensations are enough to count a multi-aggregate
  write as declared, and whether the acknowledgement belongs on the aggregate, the
  command or the bulk request.
