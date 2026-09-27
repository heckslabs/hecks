# Postgres and Sqlite journal compaction, gated by how far each bound projection has caught up

**Status:** Proposed. Builds on [ADR 0053](0053-transactional-outbox-for-domain-events-and-effects.md) (the outbox) and on #895, which stopped `PostgresEra`'s redundant boot-time journal replay. Nothing below is built yet.

## Context

The entry table (`<aggregate>_entries`), the shared `events` table and `hecks_outbox` have no DELETE/TTL/archival path on Postgres or Sqlite — nothing trims them, ever. Storage grows without bound, and so does the cost of anything that scans a full journal.

`Heki` is the only adapter with compaction (`lib/hecks/adapters/driven/heki/journal.rb`, `bin/heki_compact`): snapshot current state, `write` it, `truncate_journal!`. It refuses outright — no override — when `Ports::Projection.binds_for` finds any `projected_by` bind on the aggregate, because `Worker#catch_up!` needs the full journal to catch a projection up. That blanket refusal is correct but coarse: an aggregate with one lagging projection never compacts at all, forever.

`Ports::Projection::Worker` already tracks how far one projection has caught up — `checkpoint = @projection.entries.length` — but only for the aggregate's *first* declared `projected_by` bind (`Projection.worker` picks `binds_for(...).first`); other declared binds are never driven through this path at all today. That's a pre-existing gap, separate from this ADR, but it means a floor computed only from `.first` would be unsafe — a second, undriven projection could still need entries the floor let go.

`Worker#catch_up!`'s `:refresh` policy resets the projection store and replays the **entire authoritative journal** from position 0, even though `:refresh` only promises to rebuild current state — it does not promise to replay history. That full replay is one valid way to reconstruct current state, not the only one: the aggregate's own table already holds current state directly. A `:refresh` rebuild that instead seeded from `authoritative.all` would need no history at all, and would keep working correctly after older entries are gone. `:strict` is different — it must verify its own store's entries are an exact prefix of the authoritative journal, which genuinely requires the original entries from position 0.

## Decision

1. **A cheap catch-up position.** Add `AppendOnly#entry_count`, default `entries.length`; Postgres, Sqlite and PostgresEra override it with a `SELECT COUNT(*)` (or an equivalent sequence read) so checking how far a projection has caught up never requires materializing its whole entry log. `Worker#checkpoint` switches to it.

2. **`:refresh` stops needing history.** `Worker#catch_up!` under `:refresh` seeds the reset projection store from `authoritative.all` — each currently-live record treated as one synthetic save — instead of replaying `Queue.new(@authoritative).entries` from position 0. `:strict` is unchanged: it still reads, and still needs, the full original journal to verify a real prefix match.

3. **The compaction floor.** For one aggregate, the floor is the minimum `entry_count` across **every** `projected_by` bind `Projection.binds_for` returns (not just `.first` — the existing worker limitation doesn't get to also be this feature's unsafe shortcut), or unbounded when none are declared. Entries at or before the floor, minus a small safety margin, are deletable.

4. **`:strict` past the floor refuses, loudly.** If a `:strict` catch-up's projection has fallen behind the floor, `catch_up!` raises a named `Runtime::WiringError` — it cannot verify a prefix it no longer has. This is a real, accepted narrowing: an aggregate that wants `:strict` semantics for a lagging projection cannot also compact past where that projection sits. Silently falling back to `:refresh` behavior was considered and rejected — a caller who asked for `:strict` asked to be told, not to have the check quietly weakened.

5. **Deletion mechanics.** A `bin/compact`, the Postgres/Sqlite peer of `bin/heki_compact`: `--dry-run` first, batched deletes (not one giant transaction) to avoid long locks on a large table, one aggregate at a time.

6. **Outbox retention, independent of the floor above.** `hecks_outbox` rows already `delivered` (or terminally `failed`) past a retention window are pruned on their own schedule — they need no journal-floor gating, since their own `status` already says whether every consumer is done with them.

7. **The `events` table is out of scope for this ADR.** Before it can be compacted the same way, something needs to confirm nothing projects directly off `events` rather than `entries` (open item below).

## Consequences

- Compaction is only ever as good as the slowest bound projection. An aggregate whose projection has stalled (crashed catch-up, an orphaned bind nothing services any more) simply never compacts past where it stalled — visibly, not silently: the floor just doesn't move.
- `:refresh` catch-up for a brand-new projection gets cheaper in the ordinary case too (one read of live records instead of a full history replay), independent of whether compaction ever runs — a real side benefit, the same shape as ADR 0053's own "a side effect worth naming."
- `:strict` and compaction are now in real tension: a domain that wants both, for the same aggregate, cannot have unbounded compaction. That tradeoff is explicit, not hidden.
- Deleting entries is a genuine loss of audit-log granularity for anyone querying the raw journal for forensic reasons. This ADR treats that as an accepted tradeoff for bounding storage growth, not something this cut preserves.

## Alternatives considered

- **Mirror Heki exactly (blanket refusal if any projection is bound).** Simpler, no `entry_count`/`:refresh` changes needed — but never compacts any aggregate with a projection at all, forever. Rejected: the whole point here is to do better than that for the common case.
- **A separate, durably-tracked watermark table.** More directly inspectable, but duplicates state the projection's own entry count already durably tracks, and needs active upkeep on every write path to stay correct. Rejected in favor of reading `entry_count` off the projection store that already exists.
- **Synthetic snapshot entries written into the journal at the compaction point**, so `:strict` catch-up stays possible past a compaction. Makes the journal's own data model stranger — a fabricated entry that corresponds to no real command — for a case (`:strict` + compaction on the same aggregate) that's already rare. Not chosen; refusing loudly (item 4) was judged more honest than fabricating history.
- **Archive-then-delete** (move compacted rows to a cold table instead of dropping them), preserving full audit history at real additional storage/engineering cost. Left as a future option, not built now.

## Open items

- Whether `events` can be compacted the same way, once it's confirmed nothing reads it directly instead of `entries`.
- `bin/compact`'s exact CLI shape and how it's invoked operationally (scheduled job vs. by hand, matching `bin/heki_compact`'s own precedent).
- Outbox retention window and where it's configured.
- Whether the pre-existing "only the first `projected_by` bind is ever driven through `Projection.worker`" gap should be fixed at the same time or tracked separately — this ADR only requires that the floor calculation itself see every declared bind, not that every bind actually gets serviced.
- Whether `rust/host` needs anything here at all, or whether this stays a Ruby-side operational tool with no Rust-parity surface.
