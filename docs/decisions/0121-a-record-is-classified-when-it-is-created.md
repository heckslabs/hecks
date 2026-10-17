# A record is classified when it is created

**Status:** Proposed. Nothing is built. Date: 2026-10-17. One of three gaps a blind recovery exercise found
(see [ADR 0119](0119-a-rate-that-varies-by-kind-and-stage-is-a-declared-table.md)).

## Context

In the recovered stock domain, a lot's kind (standard, maturing, event voucher, archival) follows from its
product label, and is fixed for the lot's life. A creating command cannot choose a value: `sets` takes a value,
an argument, or arithmetic, never "this if that". So `Receive` defaults `kind` to standard, and three policies
on `LotReceived` each match one label with `where` and trigger a `Classify` command. That is three reactions
and an extra command to state one fact that is known the moment the lot exists. Between the create and the
reactions, the record briefly holds a kind it does not have.

## Options

1. **BLUEBOOK: a conditional expression.** `sets :kind, to: (label == "X" ? "maturing" : ...)` or a `case`.
   It is general, but it grows the expression language in both runtimes for one pattern, and nested
   conditionals are where domain rules go to hide.
2. **BLUEBOOK: read the kind from a declared table.** If [ADR 0119](0119-a-rate-that-varies-by-kind-and-stage-is-a-declared-table.md)
   lands, `sets :kind, to: ProductKinds[label]`, with a declared default row. The mapping is visible data, and
   the same word serves rates and classifications.
3. **HECKSAGON: classify at the edge.** The domain's `Receive` takes `kind` as an argument, and the mapping
   from a legacy label to a kind lives where legacy names are translated: the anti-corruption layer of a
   bubble's hecksagon. The domain then never sees raw labels as a rule at all.

## Recommendation

Option 3 when the label is a legacy artifact, which it was here: the kinds are the domain's language and the
labels are the old system's. Option 2 when the classification is itself a domain rule a business person owns.
Not option 1.

## Open items

- Whether the hecksagon's legacy mapping (the bubble design's field mappings) can map a value as well as
  rename a field, and so carry option 3.
- If both 2 and 3 are wanted, a rule of thumb for which one a mapping belongs to.
