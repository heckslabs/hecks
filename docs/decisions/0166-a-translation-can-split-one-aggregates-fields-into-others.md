# A translation can split one aggregate's fields into others

**Status:** Proposed. Date: 2026-10-31. Planned for 7.0.1. Needs the owner's approval before any
code lands: it adds a translation operation and touches the lineage path that every era mint runs.

## Context

Hecks 6.0.0 split `ConsoleSettings`' one `Collection` aggregate into four: `Collection`
(identity-free presentation), `CollectionLayout` (columns and detail fields), `CollectionRules`
(preconditions and field formats) and `CollectionIdentity` (how new records are named). The split
was not given a translation edge. Production's `ConsoleSettings` journal sits at one era with 21
`Collection` rows, each holding all seventeen fields, so the platform cannot boot on 6.0.0 and
is held on 6.0.0's sibling release.

The translation language cannot express the split. Its operations act on one aggregate's own
fields: `rename`, `move` (within an aggregate), `convert`, `retype`, `backfill`, `derive`,
`rekey_to`, `drop`. Writing a row into a second aggregate, from a field of the first, is not one
of them. An edge can therefore rename or derive a field, but cannot give each new aggregate its
own rows. Writing such rows by hand in SQL is refused: ADR 0118 removed `compute ... sql:` and
`rekey sql:` precisely because no rule that only a person can verify should reach a mint.

## Decision

Add one translation operation, `split`, that writes rows into another aggregate from the rows
of the source aggregate, without a SQL expression:

```ruby
aggregate "Collection" do
  split into: "CollectionLayout", keyed_by: :agg, fields: %i[columns detail_fields detail_field_columns]
  split into: "CollectionRules",  keyed_by: :agg, fields: %i[preconditions field_formats]
  split into: "CollectionIdentity", keyed_by: :agg,
        fields: %i[identity_field identity_strategy identity_source identity_prefix identity_extra_json]
  drop :columns, :detail_fields, :detail_field_columns, :preconditions, :field_formats,
       :identity_field, :identity_strategy, :identity_source, :identity_prefix, :identity_extra_json
end
```

Rules, each enforced by the translation builder and not by review:

1. `keyed_by` names a field present in both aggregates, and the target's identity must equal it.
   A split whose target identity is not that field is refused at build time.
2. A `split` copies each source row's named fields into exactly one target row. A target row that
   would be created twice for one key is refused.
3. Every target aggregate the new shape declares must receive rows from exactly one `split`, or
   from a `backfill` that gives the field a default. A target left without a source is refused,
   so no aggregate is created empty by accident.
4. A `split` is a pure function of the source row. It has no clock, no sequence, and no reference
   to another aggregate's rows, so a rehearsal and a mint agree.

The operation is implemented in the Ruby builder (`translation_builder.rb`), in the lineage
transform that a mint runs (`postgres_era/lineage/transform_sql.rb` and `merge_writes.rb`), and in
the memory and SQLite adapters, which share the same row function. The Rust parser's keyword table
and generated vocabulary gain `split`, and a conformance spec holds the Ruby and Rust results to
the same answer, as ADR 0029 requires for every translation operation.

## Consequences

- The `ConsoleSettings` edge from era 1 to the 6.x shape is written with four `split`s and no SQL.
- A rehearsal of that edge against a copy of the platform's data is the gate before any production
  mint. The rehearsal already exists (`rehearsal_run.request`); it needs the edge to load.
- The language grows by one operation. Every bluebook that uses only the existing operations is
  unchanged.
- The release is 7.0.1, not 6.x: a new operation is a minor language change, and the platform's
  pin moves to it deliberately.

## Alternatives considered

- **Revert the `ConsoleSettings` split** (the other option the owner was offered). Simpler, and it
  keeps 6.0.0 unchanged for the platform, but it undoes a design the console already uses.
- **Read both shapes in the console.** Unblocks the platform without a language change, but leaves
  two shapes in production indefinitely and a mint that never reconciles them.
- **A SQL edge with an approval file.** Refused by ADR 0118. A person's approval is not a rule.
