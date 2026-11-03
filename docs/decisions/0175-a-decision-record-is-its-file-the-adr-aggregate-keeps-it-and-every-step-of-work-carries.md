# A decision record is its file, the Adr aggregate keeps it, and every step of work carries one out

**Status:** Accepted (owner requirement, 2026-11-02). Date: 2026-11-02. Built on this branch: the `AdrFiles` adapter
(`lib/hecks/adapters/driven/adr_files.rb`), the `WorkDecisions` port (`lib/hecks/hecks/adapters/work_decisions.rb`)
and the `decision_records` quick-gate check (`spec/decision_records_spec.rb`).

## Context

The Tickets bluebook declared an `Adr` aggregate (draft, accept, supersede) and a `Work` aggregate whose
steps could name the decision they carry out. Neither touched `docs/decisions`. Every record there was
written by hand, numbered by looking at the directory, and given a status line in whatever words its author
chose: about twenty different leading words across 174 records ("Shipped", "Investigated", "RESOLVED",
"Partly built"). Seven numbers were taken twice by sessions that drafted at the same time, and a spec
(`adr_numbers_unique_spec.rb`) only stopped the list from growing. A `Tickets::Adr` row, when anyone
drafted one, lived in a local Sqlite file and said nothing about the record it named. No Work row named a
decision: the reference was optional and no caller passed one.

## Decision

1. **A decision record is its file, and `Tickets::Adr` is read from it.** The Hecks domain binds
   `Tickets::Adr` to the `AdrFiles` persistence adapter. It loads one row per `NNNN-slug.md` under
   `docs/decisions` and `docs/implemented/decisions`, from the file's header only: the number from the file
   name, the title from its `# ` line and the status from the first word of its status line. A save writes
   the title and the status's leading words back and leaves the author's prose alone. A new number gets a
   new file, `docs/decisions/NNNN-slug.md`, with the three headings to fill in. A record is never deleted;
   the adapter refuses it.
2. **The lifecycle is the status vocabulary.** A record is `proposed` when drafted, then `accepted` or
   `withdrawn`, and an accepted one may be `superseded`, optionally by a named successor
   (`Superseded by [ADR NNNN](NNNN-slug.md).`). A status line leads with one of those words, capitalised,
   and the author may write anything after it. The 33 records that led with another word were given the
   lifecycle word in front of their own text, so nothing was reworded.
3. **Records are written through commands.** `hecks tickets Adr.draft! adr.value=NNNN title.value=…`
   writes the file; `Adr.accept!`, `Adr.withdraw!` and `Adr.supersede! superseded_by.value=NNNN` move it.
   A number already held is refused at draft time (`Draft creates a Adr that already exists`).
4. **Every step of work carries out a decision that stands.** `Work.plan!` takes `decision` as a required
   reference, so a number no record holds is refused. A step planned or reopened asks the `WorkDecisions`
   port whether its decision is accepted, since one Work command cannot read an Adr row; a refusal lapses
   the step with the reason. `Work.lapse!` now takes the reason, so the same command serves this and the
   superseding of a decision. The two policies that file steps themselves name theirs: a red spec is
   planned under ADR 0174, and the push-due step under this record until the push nudge has a decision of
   its own.
5. **The quick gate checks the records.** The `decision_records` gate row runs
   `spec/decision_records_spec.rb`: every record has a title, a status that leads with a state of the Adr
   lifecycle (read from the Tickets bluebook, not repeated), a number no other record holds outside the
   known duplicates, and a successor that exists when it names one. It replaces `adr_numbers_unique_spec.rb`
   and keeps its list of known duplicates, which only shrinks.
6. **Specs and gates read the records and write none.** The memory environment's world sets
   `persisted_by("AdrFiles") { writes false }` for Tickets, so a run under `HECKS_ENVIRONMENT=memory` loads
   the real records and keeps whatever it drafts or accepts in its own memory. The standalone Tickets
   hecksagon, which behaviors, fuzzing and `model_check` boot, keeps Adr in Memory.

## Consequences

- A session writes a decision with `Adr.draft!` and plans its work with `Work.plan! … decision=NNNN`. A
  step under a proposed decision lapses at once and says to accept it first.
- Accepting a decision is the owner's call, as before; the command only records it in the file.
- A copy whose `hecks.local.hecksagon` binds `Tickets::Adr` to another store now has two authoritative
  bindings and refuses to boot; the line is removed so the files are the store.
- Status words outside the lifecycle ("Shipped", "Built") now come after the lifecycle word. Readers who
  want to know whether something is built read the prose, as they did before.

## Alternatives considered

- **A port that writes the file on each Adr event, with rows kept in a database.** Rejected: the row and the
  file could disagree, and a session that edited a record by hand would leave the row stale. The file is
  what people read, so it is the store.
- **An environment hecksagon that rebinds Adr to Memory for specs.** Rejected because a second binding is
  refused as ambiguous; a world setting on the one binding does the same without a second bind.
- **A `given` on `Work.Plan` that reads the decision's status.** Rejected: a command changes and reads one
  aggregate, so the cross-aggregate check is a port, as the area and cap checks on `Work.Start` already are.
