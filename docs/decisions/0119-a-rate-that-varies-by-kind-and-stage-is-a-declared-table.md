# A rate that varies by kind and stage is a declared table

**Status:** Proposed. Nothing is built. Date: 2026-10-17. One of three gaps a blind recovery exercise found
(the others are [ADR 0120](0120-an-event-carries-the-record-fields-its-reactions-read.md) and
[ADR 0121](0121-a-record-is-classified-when-it-is-created.md)).

## Context

An agent recovered a small stock-ageing domain from a minified program and modeled it in Hecks. The rule is a
rate: how much a lot's grade changes in a day depends on the lot's kind (four kinds) and the stage of its life
(two or three stages per kind). Written down it is a table:

| kind | stage | change |
| --- | --- | --- |
| standard | before its sell-by day / after | -1 / -2 |
| maturing | before / after | +1 / +2 |
| event voucher | more than 10 days left / 6 to 10 / 1 to 5 | +1 / +2 / +3 |
| event voucher | event passed | to 0 |

Hecks has no way to say this. The expression language has comparisons, logic, membership and arithmetic
(`lib/hecks/bluebook/expression/projection.json`), but no conditional, no `min`/`max` and no lookup. So the
model became eight policies on one event, each a `where` on kind and days left and a trigger with a literal
`change:`. They differ only in one guard and one number, and nothing checks that together they cover every kind
and stage exactly once.

Rates like this are common in exactly the systems a brownfield bubble wraps: fees by tier, tax by bracket,
discounts by customer class, penalties by days overdue.

## Options

1. **BLUEBOOK: a declared table, read by an expression.** A chapter declares `table "DailyChange"` with named
   keys and rows, and an expression reads a row by key: `sets :grade, to: grade + DailyChange[kind, stage]`.
   The table is data, so both runtimes read it, model_check can check it is total over closed-set keys, and a
   rate change is a row edit.
2. **BLUEBOOK: a policy with branches.** One policy whose trigger has several `when` arms, each a guard and its
   own `with:`. It removes the repeated `on` and `trigger`, but the rates stay spread across guards, and
   totality is as hard to check as today.
3. **Nothing.** Keep one policy per row. It is explicit and each policy is checked, but the table a domain
   expert would recognize is never written down.

## Recommendation

Option 1, because the table is the domain fact and the other two only reorganize its symptoms. It needs:

- **BLUEBOOK:** the `table` word.
- **Expression grammar:** a lookup operator, in Ruby and Rust together, since a gap would be a parity hole.
- **model_check:** a totality check over keys typed by `one_of:` value objects.

## Open items

- Range keys (`1..5` days left): read directly, or require a stage to be derived first, as above.
- Whether a missing row is a refusal at dispatch or a load-time error when the keys are closed sets.
- Whether [ADR 0121](0121-a-record-is-classified-when-it-is-created.md)'s label-to-kind mapping is the same
  word with a one-column key.
