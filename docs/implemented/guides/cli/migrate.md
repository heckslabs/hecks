# migrate

<!-- prose anchor="Concept" purpose="concept" supports="doc:docs/decisions/0163-hecks-is-one-context-in-task-modules-and-a-bang-is-the-only-sign-of-a-write.md code_file:lib/hecks/hecks/migrate/migrate.bluebook" -->
Move a store between shapes. Use it when a bluebook's shape changes and the stored records must
follow: hold the first era, compact a journal, or rehearse the next era before it is minted.

**Concept.** An era is one shape a store's records were written in. When a shape changes, a
translation edge says how the old records become the new shape. A rehearsal runs that change
against a copy of the data first, so you can see whether a mint would go through.

<!-- prose anchor="Examples" purpose="tutorial" mentions="command:RehearsalRun.request! command:SchemaRevision.compact! command:SchemaRevision.compaction" supports="code_file:lib/hecks/hecks/migrate/migrate.bluebook" -->
**Example: rehearse the next era**

```sh
hecks RehearsalRun.request!
```

Rehearses the domain's next era against a copy of its data, and says whether a mint would go
through.

**Example: compact a journal the store has already projected**

```sh
hecks SchemaRevision.compact! domain.value=examples/banking
```

Without `confirm.value=true` it names what it would delete and deletes nothing.

**Example: see what compacting would delete**

```sh
hecks SchemaRevision.compaction domain.value=examples/banking
```

Reads the journal and reports what compacting would remove, without removing it.

## Commands

Every command and query this module lists for a person, generated from its bluebook. `hecks migrate` prints the same list.

<!-- generated:begin cli section=migrate -->
### SchemaRevision

One change to a domain's journal of eras, and how it ended: a store's upkeep.

- `hecks SchemaRevision.hold_first! <domain> --confirm`: Hold the first era of a domain that holds none, as its first boot would
- `hecks SchemaRevision.rename_domain! <domain> --confirm`: Move a renamed domain's held eras and journal from its former name to its current name
- `hecks SchemaRevision.merge_tail! <domain> [winners=] --confirm`: Interleave the old world's writes since the cut into the live head, by their ordinals
- `hecks SchemaRevision.reattest! <domain> era= --confirm`: Freeze an era's held text as it now stands, after a person has read it
- `hecks SchemaRevision.backfill_projections! <domain>`: Store the shape every held era froze with, for the eras that predate it
- `hecks SchemaRevision.compact! <domain> [aggregates=] --confirm`: Delete the journal entries a Postgres or Sqlite aggregate has already projected
- `hecks SchemaRevision.compact_heki! <domain> [aggregates=] --confirm`: Empty a Heki aggregate's journal, keeping the snapshot
- `hecks SchemaRevision.write_translation! <domain> --confirm`: Write the one translation edge that leads the latest held era to the current shape
- `hecks SchemaRevision.reconcile! [<domain>] --confirm`: Write the translation edges that lead every domain's latest held era to its current shape
- `hecks SchemaRevision.mint_held! [<rehearsal_verdict>] [watermark=] --confirm`: Mint the Hecks domain's next era when its shape moved, before the push train writes
- `hecks SchemaRevision.release_mint! <domain> --confirm`: Mint a domain's next era once for a release, and move the shape ledger to the released shapes
- `hecks SchemaRevision.scaffold_translation <domain>`: The edge file that would lead the latest held era to the current shape.
- `hecks SchemaRevision.audit_translation <domain>`: The audit of the edge that leads the latest held era to the current shape.
- `hecks SchemaRevision.compose_translation <domain>`: The one edge write_translation would write, and the stale edges it would delete.
- `hecks SchemaRevision.reconcile_plan [<domain>]`: The dry run of SchemaRevision.Reconcile: per domain, the held era, the current shape, the edge it would write, the edges it would delete, and the verdict.
- `hecks SchemaRevision.attestation <domain> era=`: An era's held text as it now stands, and whether it still matches its digest.
- `hecks SchemaRevision.compaction <domain> [aggregates=]`: What compacting the domain's journals would delete, without deleting it.
- `hecks SchemaRevision.boot_status <domain>`: The boot status of each bluebook under a domain directory: current, behind by a recorded implicit move, superseded, or unminted, with the held and current labels and the reason; read from its own database when it declares one, else from the committed ledger.
- `hecks SchemaRevision.boot_resolution <domain>`: What a boot would resolve for each bluebook under a domain directory, from its own database: status, held label, current label, ordinal and reason. Writes nothing.
- `hecks SchemaRevision.sqlite_status <domain>`: The SQLite databases a domain's worlds name, read-only: per aggregate table the columns the aggregate declares and the table lacks (added on the next open), the columns it keeps that the aggregate no longer declares, and the tables no aggregate maps to.
- `hecks SchemaRevision.event_trace <domain> [event=] [run=] [last=] [database=]`: Per recorded event: the policies that listen to it and what became of each delivery (delivered, refused with its reason, pending, claimed, failed, or no record), the events nobody listens to, and the policies whose event never occurred. Reads only; Memory keeps no log.
- `hecks SchemaRevision.projection_audit <domain>`: Every era of each bluebook under a domain directory whose stored hash is not the hash of its stored projection: domain, ordinal, stored hash and recomputed hash. Writes nothing.
- `hecks SchemaRevision.mint_plan <domain> [bluebook=] [rehearsal_ref=] [rehearsal_watermark=] [rehearsal_verdict=]`: Runs every guard a mint runs against the live store, read-only and in seconds: the era resolution and decision, the edge checks, the coverage check, the translation audit (Ruby only; parity needs the full rehearsal), the watermark rule, the world's flags and markers, and the freshness of a rehearsal ref when one is passed. Names one bluebook of the directory, the first by default. Answers each guard's status, whether the mint would go ahead, and the exact mint command to run.

### Seal

The head a domain's journal chain had when the rows before it were compacted away.

- `hecks Seal.latest <domain>`: The newest seal a domain holds.

### RehearsalRun

One rehearsal of a domain's next era against a copy of its data: what a mint would do, and what it would refuse.

- `hecks RehearsalRun.request! <domain> [pin=]`: Rehearse a domain's next era against the copy of its data its world names, say whether a mint would go through, and print the whole outcome
<!-- generated:end cli -->
