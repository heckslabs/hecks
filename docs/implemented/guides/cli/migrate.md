# migrate

Move a store between shapes. Use it when a bluebook's shape changes and the stored records must
follow: hold the first era, compact a journal, or rehearse the next era before it is minted.

**Concept.** An era is one shape a store's records were written in. When a shape changes, a
translation edge says how the old records become the new shape. A rehearsal runs that change
against a copy of the data first, so you can see whether a mint would go through.

**Example: rehearse the next era**

```sh
hecks RehearsalRun.request!
```

Rehearses the domain's next era against a copy of its data, and says whether a mint would go
through.

**Example: compact a journal the store has already projected**

```sh
hecks Era.compact! domain.value=examples/banking
```

Without `confirm.value=true` it names what it would delete and deletes nothing.

**Example: see what compacting would delete**

```sh
hecks Era.compaction domain.value=examples/banking
```

Reads the journal and reports what compacting would remove, without removing it.
