# Rehearse an era before minting it

**Status:** Proposed. Built as a draft: the aggregate, its two strategies and the specs are in. Date: 2026-10-11. Whether a domain at a pin would mint its next era against a copy of its real data, and what the mint would refuse, had no verb. This gives it one.

## Context

A "rehearsal" in Hecks was only a flag: `promotion_run.promote` without `--confirm`, `publishing_run.publish`, a codemod's "or the rehearsal of it". Nothing answered, end to end, "would this domain at this pin mint its next era against a copy of the real data, and what would it refuse?" The pieces existed and each ran only inside a mint:

- `Runtime::StorageShape` names a shape (`introspection.shape` gives its label, and only that).
- `era.audit_translation` and `era.scaffold_translation` read a database that already holds eras, and answer about the edge that leads its latest era to the shape.
- The Rust host's mint audit (`reference_validate`, run by the `validate_harness` binary) holds every stored value to what dispatch holds an offered one to, including a closed set. The Ruby audit's first layer does not check a closed set; only the lifecycle and the invariants of a value object that is read.
- A hand-built attempt hit three walls: the CLI's own domain would not boot the target in `HECKS_ENVIRONMENT=memory` because the target's hecksagon requires `persisted_by` binds, `development` went looking for a database named `hecks`, and the shape label was the only thing a read gave back.

The user decided where the copy of the data comes from: the subject's **world file**, not a command argument, and not something Hecks creates by itself at first.

## Decision

Every decision says which side it is on.

1. **Bluebook: a `RehearsalRun` aggregate, in its own chapter file.** `lib/hecks/hecks/rehearsal.bluebook` declares `Hecks.bluebook "Hecks"`, so it merges into the same chapter as `custodian.bluebook` (ADR 0096 point 2). It is Operations, not Maintenance: it acts on a client's domain and needs no hecks checkout, so it is not a Codebase `*Run` although it follows their protocol (requested, asked, judged by the facts). A new file because `custodian.bluebook` is already the largest chapter of that module and a rehearsal shares no value object with its aggregates.
2. **Bluebook: its lifecycle is `requested -> booted -> audited -> judged`, with `withheld`, `refused` and `failed` as the other ends.** `judged` means the mint would go through; `withheld` means a rehearsal ran and the answer is that it would not (the verdict says which way); `refused` means it was never run (no copy declared, a pin that is not this install, a store that would not prepare); `failed` means it broke after it began. `mark :failure` covers the last three, so the launcher's `--wait` exits non-zero for a mint that would not go through.
3. **Bluebook: the verdict is a closed set, with invariants.** `would_mint`, `would_refuse`, `needs_edge`, `cannot_boot`. A domain that does not load is `cannot_boot`, an answer and not a breakdown. A shape that changed with no edge leading on is `needs_edge`. A stored row the audit refuses, or an edge that needs an approval it has not got, is `would_refuse`. Invariants: no `would_mint` while a refused row stands, none for a domain that did not boot, and no more than fifty rows are held while the total counts all of them.
4. **Bluebook: the report is value objects the run returns.** Shape before and after (`ShapeLabel`), the era a mint would hold (`Minting`: none, first, next), whether an edge leads on and is approved, the refused rows (`Aggregate#id`, a rule of `value`, `lifecycle` or `reference`, and the audit's own wording), the other engine's `Parity`, and a list of `Limit`s: what was not checked and why. A rehearsal states its limits.
5. **Hecksagon: nothing of a rehearsal is kept.** `Hecks::RehearsalRun.persisted_by("Memory")` binds the aggregate whatever the world's `default_adapter` is. The facts are returned to the caller as the run's report; Hecks's own journal does not hold them.
6. **Hecksagon: the copy of the data is named by the subject's own `.world`.**

   ```ruby
   Hecks.world "Shop" do
     rehearsed_by("Postgres") do
       connection_env "SHOP_REHEARSAL_SERVER"   # the NAME of a variable; its value is a postgres:// URL
       mode           "dump"                    # empty | dump | readonly_copy
       dump           "../rehearsal/shop.dump"  # relative to the bluebook directory
       drop_after     true
     end
   end
   ```

   The world language already expresses this: a verb with an adapter name and a block of settings is how `persisted_by`, `opened_by` and `deployed_to` are written, and the builder records any verb. No language change was needed, so none was made, and the Rust parser has no world path to follow. A literal connection (`database`, `url`, `user`, `password`) in the block is refused with "name the environment variable", so the file holds no secret and values arrive through `op run`.
7. **Hecksagon: one port, `RehearsalStore`, two strategies chosen by the world.** `survey` prepares the copy and loads the domain against it; `examine` runs the mint's audit over the data and drops the copy. The strategies are `memory` (a JSON document of eras and records, for specs and fixtures) and `postgres` (a throwaway database named from the run key on the server `connection_env` names; a dump is restored with `pg_restore` or `psql` as argv arrays and `PG*` variables, never a shell string and never a password on a command line). A `readonly_copy` is a database somebody else made, read in a read-only session and never created or dropped, and refused when it is a database the domain's own world persists to. A *host* strategy, reading a running host's data through its API, is described and not built: it needs an authenticated, read-only export route the host does not have, and this change keeps everything local.
8. **Hecksagon: the copy is dropped by the ask that last needs it.** Reactions are limited to a depth of five; a request, a survey, a boot record, an examination, an audit record and a verdict is exactly five. A separate drop reaction would be a sixth, and a reaction that never arrives would leave a database. `examine` drops in an `ensure`, and a survey that fails drops before it refuses.
9. **Hecksagon: no era is written.** The adapter loads the domain with `HeldDomain` (nothing bound or booted), points the journal store at the copy (`HeldDomain#read_from`), and calls the audit that already exists. It never calls the era gate a boot calls, because that would use the world's own database.

## What was measured

The unverified claim, that attaching a vendored package left the shape label unchanged and so minted no era, was checked with a real host.

- Stand-in: a `Shop` domain (Widget, Order) with `cms` and `newsletter` vendored, then `page_types` (five aggregates) attached. The shape label of `Shop` is `4312eb` before and after; the attached package is its own domain with its own label (`PageTypes fd2008`).
- The all-Rust host booted at the before shape on a throwaway database held era 1 (`hold_first`). A second boot at the after shape against the same database decided `use_existing`: `/version` still reported `4312eb`, `hecks_eras` still held one row, and the host IR was byte-identical. No era was minted and no mint audit ran.
- The attached aggregates are not era-versioned at all: the host's lineage lists only the domain's own aggregates, and their writes go to the generic journal. A change to a vendored package's shape is not a mint, and so cannot be refused by one. The rehearsal says so as a limit whenever a chapter is attached.
- Control: adding an aggregate to `Shop` itself (`c7e5e6`) made the host refuse to boot and `era.audit_translation` answer "no translation edge leads 4312eb to c7e5e6". A rehearsal of that domain answers `needs_edge`.

## Consequences

- `hecks rehearsal_run.request! domain=<dir>` answers the question from a checkout of any pin: run it from the install the pin names; a `pin=` is checked against the running release or commit and refused when it is not that install.
- The Ruby audit and the Rust audit disagree about a closed set. A rehearsal runs both when a `validate_harness` is built (`HECKS_VALIDATE_HARNESS`, or `cargo build --bin validate_harness` in `rust/host`) and reports `parity` as `agree` or `differ`; the union of their rows is what is refused. It never builds the binary.
- A request is journaled nowhere by Hecks, so the report in the terminal is the record; a caller that wants one keeps it (CI, a ticket).
- The Ruby era readers write when they read: `Lineage#eras` backfills an archived text. A copy made by the rehearsal is its own to touch; a `readonly_copy` read in a read-only session refuses where such a backfill is due, and says so.

## Not decided here

- Whether a rehearsal that is `withheld` files a Finding (Tickets chapter), by the same policy that files one for a late lane. The report carries what a Finding needs.
- Whether the approval trailer rules of a lane (`Release-Approved-By`) should require a rehearsal that is `judged` for an edge with a compute or rekey rule, instead of the recorded `rehearsal` block `approve_translation` takes today.
- The Rust host as the first engine, once its mint audit can read a stored copy itself.

## Alternatives considered

- **A flag on `Era` (`--rehearse`).** The era chapter's `rehearsal` attributes already mean something else (the approval block a person recorded on a compute or rekey edge). A flag cannot carry a verdict, a limit list or a lifecycle.
- **Extend `PromotionRun`-style Codebase aggregates.** They need a checkout; a client has none.
- **The store as a command argument.** The user decided against it: a connection belongs to the world.
- **A schema in the supplied database instead of a database.** A dump carries its own schema names, so a restore into a renamed schema is a rewrite; a database is isolated whatever the dump says.
- **Booting the subject with the real era gate against the copy.** It resolves its settings from the world's own `persisted_by`, which in a deployed context names production.
