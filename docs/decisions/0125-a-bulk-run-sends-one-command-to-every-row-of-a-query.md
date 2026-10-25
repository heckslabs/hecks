# A bulk run sends one command to every row of a query

**Status:** Accepted. Built on this branch, not released. Date: 2026-10-24.

## Context

A Rails application changes many records at once with `update_all` or a loop over a
scope. Hecks has no update that skips the domain, and should not get one: every change
goes through a command, its givens and its events. But a caller still needs to say
"freeze every open account of this customer" once, and to learn which rows took the
command and which refused it and why.

The runtime already does this for a policy. A `for_each` policy runs a declared query,
works out which key of the trigger addresses a row (`Command#addressing_key_for`), sends
the trigger once per row, and records `delivered` or `delivered: false` with the
refusal's message per row (`PolicyInterpreter::FanOut`). Nothing lets a caller start
that fan-out directly.

## Decision

1. **A `Bulk` chapter holds the record.** `lib/hecks/bulk/bluebook/bulk.bluebook`
   declares `BulkRun`, shaped like the `*Run` aggregates of the Hecks chapter: `Request`
   records the verb, the query it runs over, the query's arguments and the mode;
   `SweepWhenRequested` asks the `Rows` port to sweep; `Record` keeps one `RowResult`
   per row (the row's id, an `outcome` of `delivered` or `refused`, and the refusal's reason);
   `Refuse` keeps why the whole run could not start. A domain attaches it with
   `attaches "Bulk"`. The chapter names no store and no adapter.
2. **The sweep is the `for_each` path, shared.** `Runtime::RowSweep` holds what a
   `for_each` policy and a bulk run both need: resolving the query's aggregate, asking
   the target command for the key a row addresses it by, and recording one row's
   delivery or refusal. `PolicyInterpreter::FanOut` calls it; so does the `RowSweeper`
   adapter that answers the `Rows` port.
3. **Rows run with the requester's authority.** A policy re-enters as the system. A bulk
   run is a caller's request, so each row is dispatched under the caller bound when the
   cascade began (`Runtime::Caller.origin`), and a command's own `role` is checked per row.
   `Request` declares no role: the target command's role is the gate, row by row.
4. **Two modes.** `best_effort` sends every row and records each outcome. `all_or_nothing`
   first dry-runs every row; if any would refuse, nothing is sent, and the refusing row
   keeps its reason while the others record that the run stopped. When all would pass,
   every row is sent inside one transaction of the target's repository, so a row that
   refuses after all (a race) rolls the others back. That needs a store that rolls back:
   a repository advertises it with the `:rollback` persistence capability (Sqlite and
   Postgres do). On any other store the run is refused before a row is read, with the
   store's name in the reason.
5. **Rows are read once, then sent.** The sweep reads the query's row identities once,
   so a command that moves a row out of the query cannot shift what is swept.
   Paging's `cursor` word parses, but no interpreter applies it yet; the step that
   compiles a bulk run to SQL replaces this single read with a cursor.
6. **Every driving adapter reaches it.** The CLI already speaks to an attached chapter when
   a line starts with its word: `banking bulk bulk_run.request! verb.value=… over.value=…
   mode.value=best_effort`, then `banking bulk query outcome run.value=…`. MCP's `dispatch`
   and `query` tools resolved names in the domain's own chapter only; the storehouse now
   reads a name the same way the CLI does (`"bulk bulk_run.request"`), so MCP reaches any
   attached chapter, Bulk included. That is the only driving-adapter change. The Ruby
   facade gives each non-creating command a module method:
   `Account.freeze_account!(over: Account.open_for_customer(reference: "C-1"), mode: :best_effort)`
   requests the run and answers the `BulkRun` record. A query's module method answers
   its rows as `QueryRows`, an Array that remembers the query and its arguments, so `over:`
   names the query and not a frozen list.
7. **An ask's adapter can reach the asking registry.** `Runtime::Asking.registry` is the
   registry whose port operation is asking, bound for the duration of the ask, so an
   adapter that answers by dispatching (as `RowSweeper` does) dispatches into the same
   boot.

## Alternatives considered

- **An `update_all`-style write that skips commands.** Rejected: it skips givens, events
  and reactions, which is what the domain is for.
- **Let a bulk run re-enter as the system, like a policy.** Rejected: any caller allowed to
  request a run could then send any command to any row.
- **Fake `all_or_nothing` on Memory by dry-running and then sending.** Rejected: it is not
  atomic, and a mode that only looks atomic is worse than a refusal.

## Consequences

- A bulk run's per-row outcomes equal dispatching each row by hand in the same order;
  `Fuzzing::BulkParity` checks it against a second boot of the same history.
- `Caller.origin` is visible to any adapter answering inside a reaction cascade; only
  `RowSweeper` reads it.
- A policy's `for_each` behaviour is unchanged, wording included.
