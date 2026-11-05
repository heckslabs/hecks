# The persisted event records who dispatched it

**Status:** Proposed. Date: 2026-11-04. Owner: to be decided. Not yet built.

## Context

The storehouse already records who made a call. `Storehouse::SOURCE_TAGS` is a closed set
(`process-manager`, `operator`, `hook`, `sidequest-agent`, `cascade`, `daemon`), and `SURFACES`
says which surface a call came through (`cli`, `mcp`, `policy`, `saga`, `reaction`). Every
dispatch, query and state call is validated against them and written to the storehouse audit
log (`lib/hecks/storehouse/audit.rb`).

The event the domain persists does not carry either value. The `events` table holds `name`,
`aggregate`, `aggregate_id`, `payload` and `occurred_at` (`postgres/ddl.rb`). So `follow`, which
reads the persisted event log, cannot say what dispatched an event. Only the audit file can, and
the audit file is outside the domain.

This is survey item 4 (`SourceTag`), which the survey calls cheap. The cheap part is the enum
and its validation, which exist. The missing part is the record.

## Decision

1. **The persisted event records its source.** `events` gains a nullable `source` column, added
   the same way on the plain and revision layouts (`postgres/ddl.rb` and the revision
   `events.rb`). An event with no source records NULL, which is what an event raised by the
   domain itself with no dispatching caller gets.
2. **The enum moves into the runtime.** `SOURCE_TAGS` moves from `Storehouse` to
   `Runtime`, and `Storehouse` re-exports it, so the dispatcher can validate a tag without
   depending on storehouse.
3. **The tag travels with the dispatch.** The request's `source` is set on each event the
   dispatch raises, when `record_event` writes it. A reaction's events record `cascade` or the
   tag of the dispatch that caused them, not nothing.
4. **Schema rule.** ADR 0182's rule 1 ("same schema") is relaxed to "same behaviour, and schema
   changes are additive only." This column is additive, so it satisfies the relaxed rule and not
   the original one. The change is recorded here so 0182 can be read against it.

## Alternatives considered

- **Store the tag in the payload.** Rejected as the main design. It needs no schema change, but
  `follow` could not filter on it without reading and parsing every payload. It remains the
  fallback if the column is refused.
- **Keep the tag in the audit log only.** Rejected. It keeps the gap: the domain's own event
  record still cannot say who caused it.

## Consequences

- **Additive migration on every layout.** A nullable column with no default needs no backfill.
  Existing rows read as NULL, which means "not recorded," not "the domain itself." Readers must
  treat the two the same unless a later ADR separates them.
- **`follow` gains a filter.** `hecks operation.follow` can take `source:`. That is a new option,
  not a change to existing output.
- **Parity.** The Rust kernel has its own event handling. Its event record needs the same field,
  or the Ruby and Rust events diverge. This ADR does not cover that port.

## Open questions

1. **`surface` as well as `source`?** The storehouse audit records both. This ADR records only
   `source`. Recording `surface` too is the same change again, so it should be decided now, not
   later.
2. **Rust port.** Whether the Rust kernel's event record gains `source` in the same release, or
   later with a parity exception recorded.
3. **Where a reaction's tag comes from.** A reaction is caused by an event, not a caller. Whether
   it records the causing event's source, or `cascade`, needs one rule.

## Verification status

Read from the code paths named above. The `events` DDL, the audit fields and the enum were read
directly. The dispatch path that would carry the tag was not traced end to end, the Rust kernel
was not checked, and no specs were run.
