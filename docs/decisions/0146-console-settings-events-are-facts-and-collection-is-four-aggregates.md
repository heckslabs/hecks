# ConsoleSettings events are facts, and Collection is four aggregates

**Status:** Accepted. Date: 2026-10-28. The event names and the `Collection` split are both done.

## Context

The DDD review found events named for the write that caused them (`LabelSet`, `ColumnsReplaced`,
`StatsReplaced`), an event named for a state instead of something that happened (`KeyReturnDue`),
and a `Collection` aggregate of thirteen commands.

## Decision

**Renamed.** Every `ConsoleSettings` event now names what happened to the thing: `CollectionLabeled`,
`CollectionKeyed`, `CollectionPlaced`, `CollectionIdentified`, `CollectionAnnotated`,
`ColumnsArranged`, `DetailFieldsArranged`, `DetailFieldColumnsArranged`, `PreconditionsRestated`,
`FieldFormatsChosen`, `PrimaryFieldChosen`, `ListQueryChosen`, `StateStyleToned`,
`StateStyleFlagged`, `StateStyleAnnotated` and `OverviewStatsArranged`. Banking's `KeyReturnDue`
is `KeyReturnRequested`: the surrender asks for the keys back, which is a thing that happened.
Nothing else subscribes to the ConsoleSettings events, and `FlagKeyReturn` follows the banking
rename. Events are not stored shape, so no translation edge is needed and the shape ledger is
unchanged.

**Language events.** The setter-style events of the language bluebooks are renamed too, and tier 3
of ADR 0134 is settled with them: see ADR 0152.

**`Collection` is four aggregates,** each keyed by the same `agg`, each one consistency boundary:

- `Collection`: how a collection is named, placed and listed (`label`, `key`, `nav_order`,
  `primary_field`, `list_query`, `extra_json`). `Declare`, `SetLabel`, `SetKey`, `SetNavOrder`,
  `SetPrimaryField`, `SetListQuery` and `SetExtra` keep their names and paths.
- `CollectionIdentity`: how its new records are identified. `Declare` and `SetIdentity`.
- `CollectionLayout`: the table columns and detail-panel fields. `Declare`, `ReplaceColumns`,
  `ReplaceDetailFields` and `ReplaceDetailFieldColumns`.
- `CollectionRules`: the dispatch preconditions and field formats. `Declare`,
  `ReplacePreconditions` and `ReplaceFieldFormats`.

A read model groups one collection, so `Curated` keeps `Collection` and `CuratedIdentities`,
`CuratedLayouts` and `CuratedRules` read the others. The Rust host buckets the four aggregates and
merges their rows by `agg` into the one entry the console reads (`reshape_collections`), declares
each part's row when it has none, and routes the moved commands to their new paths.

**No translation edge.** `ConsoleSettings` is a framework member, which the shape ledger does not
hold, and the host saves the whole configuration on every save, dispatching each part even when
empty. A row stored before the split still carries its old list fields in `Collection`; the merge
reads `Collection` first and the newer rows after it, so the new aggregates win, and the first save
fills them. `presentation_tests` pins that order.

## Consequences

- The banking IR golden changed by the two renamed lines only; the generator could not run here
  (the installed JSON version reformats every golden), so the lines were edited to match its output.
  Regenerate with `GOLDEN=rewrite` on a machine with the pinned JSON and expect no further diff.
- `docs/generated/diagrams/banking/dispatch.mmd` was edited the same way.
