# A bulk run has no all-or-nothing mode, because the aggregate is the transaction

**Status:** Accepted. Built on this branch, not released. Date: 2026-10-27. Amends [0125](0125-a-bulk-run-sends-one-command-to-every-row-of-a-query.md) item 4 and [0129](0129-a-bulk-run-compiles-to-one-update-when-its-store-provides-set-transform.md) item 5, and settles the open question in [0137](0137-an-aggregate-is-the-transaction-boundary-and-model-check-reports-what-crosses-it.md).

## Context

ADR 0125 gave a bulk run two modes. `best_effort` sends the command to every row and keeps
each outcome. `all_or_nothing` dry-runs every row, sends none if any would refuse, and
otherwise sends all of them inside one transaction of the target's store, rolling the
others back if a row refuses after all.

The second mode makes a transaction span many instances of one aggregate. That breaks the
rule ADR 0137 states: a command changes one aggregate instance, and everything else is
eventually consistent. A business rule that needs several records to change together is an
invariant, and ADR 0081 says such a rule gets an aggregate that owns it. A run that spans
the records hides that missing aggregate.

Nothing used the mode. A search of every project found it only in the repository's own
specs and documents, and ADR 0125 gives no use case for it beyond offering both modes.
With the mode gone, the other value of `mode` is the only one left, so the argument no
longer chooses anything.

## Decision

1. **A bulk run has one behaviour: it sends the command to every row and keeps each
   outcome.** Each row is its own transaction, under the requester's authority (ADR 0125
   item 3). A row that refuses keeps its reason and the run goes on.
2. **`mode` is removed from the request.** `Bulk::BulkRun` no longer holds a `Mode`, the
   `Request` command takes none, the Ruby form is `freeze_account!(over: …)` with no
   `mode:` keyword, and the CLI and MCP request carries only the verb, the query and its
   arguments. `Mode`, `Plan#all_or_nothing?`, `Sweep.mode_refusal`, the rollback path and
   the `Declined` and `RolledBack` errors are gone.
3. **The compiled path loses its rollback branch.** ADR 0129 item 5 no longer applies:
   a statement that skips a row has nothing to undo, since a skipped row is dispatched by
   hand as before (ADR 0129 item 4).
4. **A rule that needs records to change together is modelled, not requested.** It becomes
   an aggregate that owns the rule (ADR 0081): a command on the owner that emits one event,
   and a policy that reacts per record. An operator sweep that must not leave a partial
   result is run again until it settles; the record lists the refused rows.
5. **The `:rollback` persistence capability is removed in a later change.** Sqlite and
   Postgres advertised it and nothing else read it once the mode went. It was left here
   because a store capability is a wider contract than one chapter's mode. It is removed
   from both adapters and from the two specs that pinned it; `transaction` itself stays,
   since the compiled bulk statement and dispatch open one.

## Alternatives considered

- **Keep the mode and warn.** ADR 0137 proposed an advisory on the run's record. It would
  keep the code, the specs and the Rust parity surface for a mode nobody calls, to tell
  the caller not to use it. Rejected: one idea, one way (ADR 0025).
- **Keep `mode` with the single value `best_effort`.** It keeps the request shape and the
  CLI argument stable. Rejected: a field with one possible value chooses nothing, and the
  word would invite the second value back.

## Consequences

- `Bulk::BulkRun` and its `Request` lose a field. The shape ledger
  (`check_shape_ledger!`) reports no chapter shape moved, because the chapter holds its
  runs in the Memory store in every corpus member; a deployed store that kept `BulkRun`
  rows with a `mode` would need a translation edge, and none is known.
- A caller that passed `mode: :best_effort` or `mode.value=best_effort` must drop it. A
  caller that passed `all_or_nothing` has no replacement in the run; it models the rule
  (item 4).
- The aggregate boundary of ADR 0137 now holds for bulk runs too, so no construct spans
  more than one aggregate instance in a transaction.
