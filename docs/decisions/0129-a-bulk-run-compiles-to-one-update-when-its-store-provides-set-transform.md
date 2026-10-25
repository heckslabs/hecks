# A bulk run compiles to one UPDATE when its store provides set_transform

**Status:** Accepted. Built on this branch, not released. Date: 2026-10-24. Builds on [0125](0125-a-bulk-run-sends-one-command-to-every-row-of-a-query.md) (a bulk run sends one command to every row of a query) and [0123](0123-an-adapter-provides-capabilities-and-a-ledger-says-which-dialects-compile.md) (an adapter provides capabilities, and a ledger says which dialects compile).

## Context

A bulk run (0125) reads its query's rows once and dispatches the command to each row in turn: one read, one write and one journal entry per row, each in its own transaction. On Sqlite or Postgres the same change is often one statement: `UPDATE accounts SET status = 'frozen' WHERE customer = $1 AND status = 'open'`. 0123 gave the store a way to say it can do that (`provides "set_transform"`) and gave every operator a rendering per dialect, so the runtime can ask both questions it needs: can this store rewrite rows in one statement, and can every rule of this command be said in its dialect.

Nothing used either answer. A caller who wants the one statement writes raw SQL, which skips the command's givens, its events and its reactions, and Hecks does not offer raw SQL.

## Decision

1. **The run asks first, then compiles or falls back.** `Bulk::SetTransform` decides, before any row is written, whether a run can be one statement. It can when the target aggregate's bound adapter provides `set_transform` (`Registry#adapter_provides?`), its repository answers the statement (`AppendOnly#set_transform?`), and every rule the command applies can be compiled for the adapter's dialect: each given and each computed `sets` passes `Hecks::Grammar.compiles_for?` and the SQL expression compiler accepts its parse. Anything else runs row by row, exactly as 0125 describes. Compiling is a speed-up the result cannot observe.
2. **What compiles.** The command acts on an existing record (`reference_to` its own aggregate), takes no argument without a default other than the row's key, and declares no `needs`, `ensures`, delegation or correction. Its mutations are `sets` of a plain `String`, `Integer` or `Float` attribute with no pattern or closed set (from a literal, an argument, `state(:field)` or a computed expression) and `increment`/`decrement` of an `Integer` attribute. A lifecycle transition and a `from:` guard compile. The aggregate has no invariants, entities, references or projected fields, since each needs a per-row check the statement does not make. The query is answered by the store, with no paging and no clause the store answers in Ruby. Expressions compile from comparisons, `&&`, `||`, `!`, `+`, `-`, `*`, the sign tests and `.set?`/`.unset?`, over literals, arguments and plain columns of matching types.
3. **One statement, one transaction.** The adapter builds `UPDATE <table> SET … WHERE <query where> AND <givens> AND <guards> RETURNING *`. The query's WHERE comes from `SqlQueryBuilder`'s own clauses, so the dialect that answers the query also answers the update. In the same transaction it journals one entry per returned row, advances the checkpoint, records one event per row and command `emits` (the payload a row-by-row dispatch would carry), and enqueues the outbox rows for those events. After the commit the relay delivers each row's reactions in query order.
4. **A row the statement skipped is dispatched by hand.** A row the query answered but the statement did not update failed a given in SQL. It is then dispatched through the ordinary path, which refuses it with the wording a row-by-row run gives, or delivers it if SQL was stricter than Ruby. The compiler adds `IS NOT NULL` guards for every column an ordering comparison, an arithmetic operator or a sign test reads, and on Sqlite a `typeof(…) = 'integer'` guard for every integer arithmetic result, so SQL never updates a row that Ruby would refuse. Where SQL and Ruby could disagree, the row is skipped and Ruby decides.
5. **all_or_nothing stays atomic.** If the statement skips any row, the transaction rolls back and the run takes 0125's all_or_nothing path, which checks every row first and words each refusal.
6. **The fuzzer holds the two paths equal.** `Fuzzing::Properties.set_transform_matches_row_by_row` replays one history twice on a SQL store, sweeps every command and query pair once compiled and once row by row, and compares the outcomes, the records left and the events recorded. It runs on Sqlite and, when a Postgres answers, on Postgres; `hecks fuzz --adapter sqlite|postgres` checks it for every domain that attaches Bulk.

## Alternatives considered

- **Refuse a run that cannot compile.** This would make a bluebook's behavior depend on its store. Rejected: the fallback gives the same answer.
- **Read every refused row's reason in SQL.** A `CASE` per given could name which given failed, but it would copy the refusal wording into SQL and drift from it. Rejected: a skipped row is dispatched, and the dispatch words its own refusal.
- **Compile invariants, references and entity rules too.** Each is a per-row check on the settled record, so it needs a subquery or a second statement per rule. Deferred: these commands run row by row until a case needs them.
- **Execute the operator ledger's `postgres`/`sqlite` forms as templates.** The forms are prose for some operators ("for text; for a list"), and a template cannot tell the type of an operand. Rejected for now: the compiler implements the subset whose forms are unambiguous and checks `compiles_for?` before using them.

## Consequences

- A bulk run's result does not depend on whether it compiled; only its cost does.
- PostgresEra declares `provides "set_transform"` but keeps its rows in one `state` document, so its repository does not answer the statement yet and its runs go row by row.
- A new operator or mutation the compiler learns has to keep the property green on both stores before it is used.
