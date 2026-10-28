# ConsoleSettings events are facts, and the Collection split waits

**Status:** Accepted for the event names; Proposed for the split. Date: 2026-10-28.

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

**Left.** The setter-style events of the language bluebooks (`MedianFieldSet`, `PieceHeld` and
their siblings) stay: they record a declaration being written into the grammar, which is the
language's own fact, and the Rust parser and IR goldens name them.

**Proposed, not done: splitting `Collection`.** The commands separate along three lines the Rust
host reaches by name (`ConsoleSettings::Collection.SetLabel` and the rest in
`rust/host/src/presentation_write.rs`): how a collection is named and placed, which columns and
fields it shows, and its identity. A split changes those command paths and the rows already stored,
so it needs the host changed with it and a translation edge with rules, the tier-3 era change
ADR 0134 has not decided. It waits for that decision.

## Consequences

- The banking IR golden changed by the two renamed lines only; the generator could not run here
  (the installed JSON version reformats every golden), so the lines were edited to match its output.
  Regenerate with `GOLDEN=rewrite` on a machine with the pinned JSON and expect no further diff.
- `docs/generated/diagrams/banking/dispatch.mmd` was edited the same way.
