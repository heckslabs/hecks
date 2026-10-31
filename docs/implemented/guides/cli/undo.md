# Undoing a write

`Introspection.Undo` answers how to reverse a command, read from the bluebook. It takes the
domain, the bluebook and the command's verb form, and prints the command that undoes it, or says
that none is declared:

```
$ exe/hecks query Introspection.undo domain.value=examples/banking bluebook.value=Banking command.value=Account.Debit
Account.Debit is undone by Account.Credit, a compensation the bluebook declares.

$ exe/hecks query Introspection.undo domain.value=lib/hecks/hecks bluebook.value=Hecks command.value=Landing.land
Landing.land has no undo declared: its bluebook names no compensating command.
```

The answer comes only from a declared `compensates` on a process manager's dispatch. It never
invents an undo, and it changes nothing. It answers per command, not per run: a run record does
not yet name the command it dispatched, so the run-level question waits on that.

## Where undo is declared

A process manager dispatches a command and may name the command that reverses it:

```ruby
dispatch Account::Debit, with: { … } do
  compensates Account::Credit, with: { … }
end
```

The compensation runs when a later step refuses. The Hecks domain declares none, so the answer for
every Hecks command is "no undo declared". The other mechanisms below are real but are not
answered by this query.

## Survey of the writes

| Command | What it writes | Undo | Mechanism |
|---|---|---|---|
| `Landing.land!` | merges a branch onto local main | none declared; a fast-forward is reverted by hand, a merge commit by a new commit | git, outside the bluebook |
| `Commit.make!` | a commit on a checkout | none; a commit is never rewritten, a fix is a new commit | git, outside the bluebook |
| `Launch.init!` | stub files of a new domain | none declared; the files are removed by hand | files, outside the bluebook |
| `Operation.run!` | dispatches a verb against a domain | only where the target domain declares a `compensates` for it | the target's process manager |
| `Shipment.ship!` | gate, land and board a branch | none declared | saga; no compensation in the Hecks domain |
| `Operation.abandon_outbox_row!` | settles one stalled outbox row as failed | not an undo: it is itself the settle | outbox |
| `Finding.reopen!` | returns a resolved or dismissed finding to triaged | reopen is the inverse of resolve or dismiss | a declared transition, in the Tickets bluebook |
| `Era` edges (ADR 0083) | a shape change to stored data | each edge declares a rollback | translation edge; the rollback is declared but no command executes it |

Every other write in the Hecks domain falls under the first mechanism: no compensation is declared,
so the query answers "no undo declared". The per-command list is the bluebook itself, and
`Introspection.Undo` reads it.
